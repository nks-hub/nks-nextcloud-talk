package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class FieldTrialsTest {
  /** Without it a rebuilt receive stream can lose its sink for the rest of the call. */
  @Test
  public void factoryDropsVideoPacketsNoReceiveStreamClaims() {
    assertTrue(MethodCallHandlerImpl.FIELD_TRIALS.contains(
        "WebRTC-Video-DiscardPacketsWithUnknownSsrc/Enabled/"));
  }
}
