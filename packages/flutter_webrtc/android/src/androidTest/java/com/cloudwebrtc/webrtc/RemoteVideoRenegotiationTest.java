package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.os.SystemClock;
import android.util.Log;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.JavaI420Buffer;
import org.webrtc.Logging;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RTCStats;
import org.webrtc.RtcError;
import org.webrtc.RtpCapabilities;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.SoftwareVideoDecoderFactory;
import org.webrtc.SoftwareVideoEncoderFactory;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;

/**
 * Replays, on two loopback peers built like the plugin's factory, the call that left a remote
 * tile grey on a Galaxy S9 on 22 November 2026: A offers first with a receive-only video line,
 * B puts its camera on that line and offers again, A answers, then A turns its own camera on
 * and offers. B only accepts VP8, as the other phone accepted fewer codecs than the S9 offered,
 * so each of A's answers and offers changes the decoders of the video line and libwebrtc
 * rebuilds its receive stream while B's packets are in flight.
 *
 * <p>The S9 lost the sink on both rebuilds; an idle emulator has not hit that timing in about
 * ninety rebuilds, so this proves the factory's field trials keep video flowing through the
 * sequence rather than catching the race. {@link FieldTrialsTest} pins the trial itself.
 */
@RunWith(AndroidJUnit4.class)
public class RemoteVideoRenegotiationTest {
  private static final int ROUNDS = 20;
  private static final long TIMEOUT_S = 15;

  private final List<AutoCloseable> cleanup = new ArrayList<>();
  private final AtomicInteger rendered = new AtomicInteger();
  private PeerConnectionFactory factory;
  private Peer a;
  private Peer b;

  @BeforeClass
  public static void initialize() {
    // libwebrtc's own log shows each receive stream rebuild and any default-stream fallback.
    PeerConnectionFactory.initialize(
        PeerConnectionFactory.InitializationOptions.builder(
                InstrumentationRegistry.getInstrumentation().getTargetContext())
            .setInjectableLogger(
                (message, severity, tag) -> Log.i("RemoteVideoTest", tag + ": " + message),
                Logging.Severity.LS_INFO)
            .createInitializationOptions());
  }

  @After
  public void release() throws Exception {
    Collections.reverse(cleanup);
    for (AutoCloseable item : cleanup) {
      item.close();
    }
  }

  @Test
  public void remoteVideoKeepsReachingItsTrackAcrossRenegotiations() throws Exception {
    factory = PeerConnectionFactory.builder()
        .setFieldTrials(MethodCallHandlerImpl.FIELD_TRIALS)
        .setVideoEncoderFactory(new SoftwareVideoEncoderFactory())
        .setVideoDecoderFactory(new SoftwareVideoDecoderFactory())
        .createPeerConnectionFactory();
    cleanup.add(factory::dispose);
    a = new Peer();
    b = new Peer();
    // Both sides open their own receive-only video line, as the app does.
    a.pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
        new RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY));
    b.pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
        new RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY));

    negotiate(a, b, 0);
    connect();

    sendCamera(b, "b-camera");
    negotiate(b, a, 300);
    assertRemoteVideoRenders("after answering the peer's camera offer");

    sendCamera(a, "a-camera");
    negotiate(a, b, 300);
    assertRemoteVideoRenders("after offering our own camera");

    for (int round = 0; round < ROUNDS; round++) {
      if (round % 2 == 0) {
        negotiate(b, a, 0);
      } else {
        negotiate(a, b, 0);
      }
      assertRemoteVideoRenders("after renegotiation " + (round + 1));
    }
  }

  private void assertRemoteVideoRenders(String step) throws Exception {
    int start = rendered.get();
    long decodedStart = framesDecoded();
    long deadline = SystemClock.elapsedRealtime() + 5000;
    while (SystemClock.elapsedRealtime() < deadline) {
      if (rendered.get() - start >= 15) {
        return;
      }
      Thread.sleep(100);
    }
    fail(step + ": the remote track got " + (rendered.get() - start)
        + " frames while its decoder produced " + (framesDecoded() - decodedStart));
  }

  private long framesDecoded() throws InterruptedException {
    AtomicLongHolder total = new AtomicLongHolder();
    CountDownLatch done = new CountDownLatch(1);
    a.pc.getStats(report -> {
      for (RTCStats stats : report.getStatsMap().values()) {
        Object decoded = stats.getMembers().get("framesDecoded");
        if ("inbound-rtp".equals(stats.getType())
            && "video".equals(stats.getMembers().get("kind"))
            && decoded instanceof Number) {
          total.value += ((Number) decoded).longValue();
        }
      }
      done.countDown();
    });
    assertTrue(done.await(TIMEOUT_S, TimeUnit.SECONDS));
    return total.value;
  }

  /** Puts a moving 640x360 picture on the peer's negotiated video line and makes it send. */
  private void sendCamera(Peer peer, String id) {
    VideoSource source = factory.createVideoSource(false);
    cleanup.add(source::dispose);
    VideoTrack track = factory.createVideoTrack(id, source);
    cleanup.add(track::dispose);
    source.getCapturerObserver().onCapturerStarted(true);
    ScheduledExecutorService capture = Executors.newSingleThreadScheduledExecutor();
    cleanup.add(() -> {
      capture.shutdownNow();
      capture.awaitTermination(TIMEOUT_S, TimeUnit.SECONDS);
    });
    // A moving gradient with a small noisy patch: full-frame noise makes VP8 drop to 3 fps at
    // the loopback's starting bitrate, and then hardly any packet is in flight.
    Random noise = new Random(id.hashCode());
    AtomicInteger tick = new AtomicInteger();
    capture.scheduleAtFixedRate(() -> {
      JavaI420Buffer buffer = JavaI420Buffer.allocate(640, 360);
      int stride = buffer.getStrideY();
      int t = tick.getAndIncrement();
      byte[] luma = new byte[stride * 360];
      for (int y = 0; y < 360; y++) {
        for (int x = 0; x < 640; x++) {
          luma[y * stride + x] = (byte) (x + y + 4 * t);
        }
      }
      byte[] patch = new byte[96];
      for (int y = 0; y < 96; y++) {
        noise.nextBytes(patch);
        System.arraycopy(patch, 0, luma, y * stride, patch.length);
      }
      buffer.getDataY().put(luma);
      fill(buffer.getDataU(), buffer.getStrideU() * 180);
      fill(buffer.getDataV(), buffer.getStrideV() * 180);
      VideoFrame frame = new VideoFrame(buffer, 0, System.nanoTime());
      source.getCapturerObserver().onFrameCaptured(frame);
      frame.release();
    }, 0, 33, TimeUnit.MILLISECONDS);
    for (RtpTransceiver transceiver : peer.pc.getTransceivers()) {
      if (transceiver.getMediaType() == MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO
          && transceiver.getMid() != null) {
        transceiver.getSender().setTrack(track, false);
        transceiver.setDirection(RtpTransceiver.RtpTransceiverDirection.SEND_RECV);
        return;
      }
    }
    fail("no negotiated video line on " + id);
  }

  private static void fill(ByteBuffer plane, int size) {
    byte[] grey = new byte[size];
    java.util.Arrays.fill(grey, (byte) 128);
    plane.put(grey);
  }

  /** B only takes VP8, so its answers and offers carry fewer codecs than A offers. */
  private void preferVp8(Peer peer) {
    List<RtpCapabilities.CodecCapability> vp8 = new ArrayList<>();
    for (RtpCapabilities.CodecCapability codec : factory
        .getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO).codecs) {
      if ("VP8".equalsIgnoreCase(codec.name) || "rtx".equalsIgnoreCase(codec.name)) {
        vp8.add(codec);
      }
    }
    for (RtpTransceiver transceiver : peer.pc.getTransceivers()) {
      if (transceiver.getMediaType() == MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) {
        RtcError result = transceiver.setCodecPreferences(vp8);
        if (result.isError()) {
          throw new AssertionError(result.error());
        }
      }
    }
  }

  private void negotiate(Peer offerer, Peer answerer, long sendBeforeAnswerMs) throws Exception {
    if (offerer == b) {
      preferVp8(b);
    }
    SessionDescription offer = offerer.describe(true);
    offerer.apply(offer, true);
    // The offerer already sends on a line the peer's last description receives on;
    // the S9 got packets for about 1.1 s before it applied the new offer.
    Thread.sleep(sendBeforeAnswerMs);
    answerer.apply(offer, false);
    if (answerer == b) {
      preferVp8(b);
    }
    SessionDescription answer = answerer.describe(false);
    answerer.apply(answer, true);
    offerer.apply(answer, false);
  }

  private void connect() throws Exception {
    assertTrue(a.gathered.await(TIMEOUT_S, TimeUnit.SECONDS));
    assertTrue(b.gathered.await(TIMEOUT_S, TimeUnit.SECONDS));
    for (IceCandidate candidate : a.candidates) {
      b.pc.addIceCandidate(candidate);
    }
    for (IceCandidate candidate : b.candidates) {
      a.pc.addIceCandidate(candidate);
    }
    assertTrue("ICE did not connect", a.connected.await(TIMEOUT_S, TimeUnit.SECONDS));
  }

  private static final class AtomicLongHolder {
    long value;
  }

  private final class Peer implements PeerConnection.Observer {
    final PeerConnection pc;
    final List<IceCandidate> candidates = Collections.synchronizedList(new ArrayList<>());
    final CountDownLatch gathered = new CountDownLatch(1);
    final CountDownLatch connected = new CountDownLatch(1);

    Peer() {
      PeerConnection.RTCConfiguration config =
          new PeerConnection.RTCConfiguration(Collections.emptyList());
      config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
      config.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
      pc = factory.createPeerConnection(config, this);
      cleanup.add(pc::dispose);
    }

    SessionDescription describe(boolean offer) throws InterruptedException {
      AtomicReference<SessionDescription> description = new AtomicReference<>();
      AtomicReference<String> error = new AtomicReference<>();
      CountDownLatch done = new CountDownLatch(1);
      SdpObserver observer = new SdpObserver() {
        @Override public void onCreateSuccess(SessionDescription created) {
          description.set(created);
          done.countDown();
        }
        @Override public void onCreateFailure(String message) {
          error.set(message);
          done.countDown();
        }
        @Override public void onSetSuccess() {}
        @Override public void onSetFailure(String message) {}
      };
      if (offer) {
        pc.createOffer(observer, new MediaConstraints());
      } else {
        pc.createAnswer(observer, new MediaConstraints());
      }
      assertTrue(done.await(TIMEOUT_S, TimeUnit.SECONDS));
      assertNull(error.get());
      return description.get();
    }

    void apply(SessionDescription description, boolean local) throws InterruptedException {
      AtomicReference<String> error = new AtomicReference<>();
      CountDownLatch done = new CountDownLatch(1);
      SdpObserver observer = new SdpObserver() {
        @Override public void onSetSuccess() {
          done.countDown();
        }
        @Override public void onSetFailure(String message) {
          error.set(message);
          done.countDown();
        }
        @Override public void onCreateSuccess(SessionDescription created) {}
        @Override public void onCreateFailure(String message) {}
      };
      if (local) {
        pc.setLocalDescription(observer, description);
      } else {
        pc.setRemoteDescription(observer, description);
      }
      assertTrue(done.await(TIMEOUT_S, TimeUnit.SECONDS));
      assertNull(error.get());
    }

    @Override public void onTrack(RtpTransceiver transceiver) {
      // The plugin's renderer attaches to the track the same way, on onTrack.
      if (this == a && transceiver.getReceiver().track() instanceof VideoTrack) {
        ((VideoTrack) transceiver.getReceiver().track())
            .addSink(frame -> rendered.incrementAndGet());
      }
    }

    @Override public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
      if (state == PeerConnection.IceGatheringState.COMPLETE) {
        gathered.countDown();
      }
    }

    @Override public void onIceConnectionChange(PeerConnection.IceConnectionState state) {
      if (state == PeerConnection.IceConnectionState.CONNECTED
          || state == PeerConnection.IceConnectionState.COMPLETED) {
        connected.countDown();
      }
    }

    @Override public void onIceCandidate(IceCandidate candidate) {
      candidates.add(candidate);
    }

    @Override public void onSignalingChange(PeerConnection.SignalingState state) {}
    @Override public void onIceConnectionReceivingChange(boolean receiving) {}
    @Override public void onIceCandidatesRemoved(IceCandidate[] removed) {}
    @Override public void onAddStream(MediaStream stream) {}
    @Override public void onRemoveStream(MediaStream stream) {}
    @Override public void onDataChannel(DataChannel channel) {}
    @Override public void onRenegotiationNeeded() {}
  }
}
