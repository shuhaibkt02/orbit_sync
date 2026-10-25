import 'package:test/test.dart';
import 'package:offline_sync/src/connectivity/domain/models/network_connection_type.dart';
import 'package:offline_sync/src/connectivity/domain/policies/network_metered_policy.dart';

void main() {
  group('Layer 3 Connectivity: Metered Network Policies', () {
    test('NetworkMeteredPolicy.any allows sync on all connection types for all payload types', () {
      const policy = NetworkMeteredPolicy.any;

      expect(policy.canSync(isMetered: false, isMedia: false), isTrue);
      expect(policy.canSync(isMetered: false, isMedia: true), isTrue);
      expect(policy.canSync(isMetered: true, isMedia: false), isTrue);
      expect(policy.canSync(isMetered: true, isMedia: true), isTrue);
    });

    test('NetworkMeteredPolicy.wifiOnlyMedia allows text/json on metered, blocks heavy media', () {
      const policy = NetworkMeteredPolicy.wifiOnlyMedia;

      // On unmetered (e.g. Wi-Fi / Ethernet), everything passes
      expect(policy.canSync(isMetered: false, isMedia: false), isTrue);
      expect(policy.canSync(isMetered: false, isMedia: true), isTrue);

      // On metered (e.g. Cellular), light JSON passes, media is blocked
      expect(policy.canSync(isMetered: true, isMedia: false), isTrue);
      expect(policy.canSync(isMetered: true, isMedia: true), isFalse);
    });

    test('NetworkMeteredPolicy.wifiOnlyAll halts all outbox traffic on metered networks', () {
      const policy = NetworkMeteredPolicy.wifiOnlyAll;

      expect(policy.canSync(isMetered: false, isMedia: false), isTrue);
      expect(policy.canSync(isMetered: false, isMedia: true), isTrue);

      // Block everything on metered
      expect(policy.canSync(isMetered: true, isMedia: false), isFalse);
      expect(policy.canSync(isMetered: true, isMedia: true), isFalse);
    });

    test('NetworkConnectionType metered classifications', () {
      expect(NetworkConnectionType.wifi.isMetered, isFalse);
      expect(NetworkConnectionType.ethernet.isMetered, isFalse);
      expect(NetworkConnectionType.cellular.isMetered, isTrue);
      expect(NetworkConnectionType.bluetooth.isMetered, isTrue);
      expect(NetworkConnectionType.vpn.isMetered, isFalse);
      expect(NetworkConnectionType.none.isMetered, isFalse);
      expect(NetworkConnectionType.unknown.isMetered, isFalse);
    });
  });
}
