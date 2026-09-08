package com.cloudwebrtc.webrtc;

import java.util.Map;
import org.webrtc.PeerConnection;

/** Forwards the native RTCConfiguration allocator flags without narrowing their bits. */
final class PortAllocatorOptions {
  private PortAllocatorOptions() {}

  static void apply(Map<String, Object> values, PeerConnection.RTCConfiguration config) {
    if (!values.containsKey("portAllocatorFlags")) {
      return;
    }
    Object value = values.get("portAllocatorFlags");
    if (!(value instanceof Integer) && !(value instanceof Long)) {
      throw new IllegalArgumentException("portAllocatorFlags must be a non-negative integer");
    }
    long flags = ((Number) value).longValue();
    if (flags < 0 || flags > Integer.MAX_VALUE) {
      throw new IllegalArgumentException("portAllocatorFlags exceeds the native integer range");
    }
    config.portAllocatorFlags = (int) flags;
  }
}
