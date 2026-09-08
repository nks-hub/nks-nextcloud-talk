package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.junit.Test;
import org.webrtc.PeerConnection;

public class PortAllocatorOptionsTest {
  @Test
  public void absentFlagsPreserveNativeDefaults() {
    PeerConnection.RTCConfiguration config = configuration();
    int original = config.portAllocatorFlags;
    PortAllocatorOptions.apply(Collections.emptyMap(), config);
    assertEquals(original, config.portAllocatorFlags);
  }

  @Test
  public void forwardsDefaultRouteAndOtherExplicitNativeFlags() {
    for (Object value : new Object[] {0, 0x400, 0x8000, 0x8400L}) {
      PeerConnection.RTCConfiguration config = configuration();
      PortAllocatorOptions.apply(options(value), config);
      assertEquals(((Number) value).intValue(), config.portAllocatorFlags);
    }
  }

  @Test
  public void rejectsMalformedFlagsInsteadOfSilentlyUsingNetworkBinding() {
    for (Object value : new Object[] {null, -1, 0x80000000L, 1024.0, "1024", true}) {
      PeerConnection.RTCConfiguration config = configuration();
      assertThrows(IllegalArgumentException.class,
          () -> PortAllocatorOptions.apply(options(value), config));
      assertEquals(0, config.portAllocatorFlags);
    }
  }

  private static PeerConnection.RTCConfiguration configuration() {
    return new PeerConnection.RTCConfiguration(Collections.emptyList());
  }

  private static Map<String, Object> options(Object value) {
    Map<String, Object> result = new HashMap<>();
    result.put("portAllocatorFlags", value);
    return result;
  }
}
