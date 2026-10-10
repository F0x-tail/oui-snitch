import 'package:oui_spy/core/classify/adv_decoder.dart';
import 'package:oui_spy/core/classify/observation.dart';

class AntiHunterClass {
  const AntiHunterClass._();

  static List<RoleHint> hints(Observation o) {
    final out = <RoleHint>[];
    for (final m in o.mfgRecords) {
      final d = hexToBytes(m.dataHex) ?? const <int>[];
      final sub = _mfgSubtype(m.companyId, d);
      if (sub != null) out.add(sub);
      final c = bleCompanyClass[m.companyId];
      if (c != null) out.add(_table(c));
    }
    final uuids = <int>{
      for (final u in o.serviceUuids) ?_u16(u),
      for (final s in o.serviceData) ?_u16(s.uuid),
    };
    for (final u in uuids) {
      final c = bleUuid16Class[u];
      if (c != null) out.add(_table(c));
    }
    for (final s in o.serviceData) {
      if (_u16(s.uuid) != 0xFEAA) continue;
      final d = hexToBytes(s.dataHex);
      final frame = d == null || d.isEmpty ? null : _eddystone[d[0]];
      if (frame != null) {
        out.add(RoleHint('beacon', 'an Eddystone-$frame beacon', 'It broadcasts a Google Eddystone beacon signal.', 5));
      }
    }
    final a = o.appearance;
    if (a != null) {
      final cat = _appearance[a >> 6];
      if (cat != null) {
        out.add(RoleHint(cat.$1, cat.$2, 'It describes itself as ${cat.$2}.', 4));
      }
    }
    return out;
  }

  static RoleHint _table(String label) {
    final i = label.indexOf('-');
    final cat = label.substring(0, i);
    final vendor = label.substring(i + 1);
    final noun = switch (cat) {
      'Audio' => 'audio device',
      'Beacon' => 'beacon',
      'Camera' => 'camera',
      'Drone' => 'drone',
      'Glasses' => 'smart glasses',
      'Health' => 'health device',
      'Home' => 'smart-home device',
      'Input' => 'input device',
      'Lock' => 'smart lock',
      'Phone' => 'phone',
      'Radio' => 'radio / body-worn device',
      'Tag' => 'tracker tag',
      'Vehicle' => 'vehicle device',
      'Wearable' => 'wearable',
      _ => 'device',
    };
    return RoleHint(cat.toLowerCase(), 'a $vendor $noun', 'It uses a Bluetooth ID that belongs to $vendor.', 3);
  }

  static RoleHint? _mfgSubtype(int company, List<int> d) {
    switch (company) {
      case 0x0006:
        if (d.isEmpty) return null;
        final s = switch (d[0] & 0x3F) {
          0x01 => 'an Xbox One',
          0x03 || 0x05 || 0x06 || 0x07 => 'a Windows Swift Pair accessory',
          0x09 => 'a Windows PC (Connected Devices Platform)',
          0x0A => 'a Windows Continuum device',
          _ => null,
        };
        return s == null ? null : RoleHint('computer', s, 'It sends a Microsoft Bluetooth signal used by $s.', 4);
      case 0x00E0:
        if (d.length >= 2 && d[0] == 0x00 && d[1] == 0xBA) {
          return const RoleHint('audio-personal', 'a Google Fast Pair accessory', 'It sends a Google Fast Pair signal, used by earbuds and speakers.', 4);
        }
        return null;
      case 0x0075:
        if (d.length >= 2 && d[0] == 0x01 && d[1] == 0x00) {
          return const RoleHint('audio-personal', 'Samsung Galaxy Buds', 'It sends the Bluetooth signal Samsung Galaxy Buds use.', 5);
        }
        if (d.length >= 2 && d[0] == 0x42 && d[1] == 0x09) {
          return const RoleHint('tag', 'a Samsung SmartTag', 'It sends the Bluetooth signal Samsung SmartTags use.', 6);
        }
        return null;
    }
    return null;
  }

  static int? _u16(String uuid) {
    final hex = hexOnly(uuid);
    if (hex.length == 4) return int.tryParse(hex, radix: 16);
    if (hex.length == 32 && hex.substring(8).toUpperCase() == '00001000800000805F9B34FB') {
      return int.tryParse(hex.substring(4, 8), radix: 16);
    }
    if (hex.length == 8) return int.tryParse(hex.substring(4), radix: 16);
    return null;
  }


  static const _eddystone = {0x00: 'UID', 0x10: 'URL', 0x20: 'TLM', 0x30: 'EID'};

  static const _appearance = <int, (String, String)>{
    0x001: ('phone', 'a phone'),
    0x002: ('computer', 'a computer'),
    0x003: ('wearable', 'a watch'),
    0x004: ('home', 'a clock'),
    0x005: ('home', 'a display'),
    0x006: ('hid', 'a remote control'),
    0x007: ('glasses', 'eyeglasses'),
    0x008: ('tag', 'a tag'),
    0x009: ('tag', 'a keyring tag'),
    0x00A: ('audio-personal', 'a media player'),
    0x00B: ('hid', 'a barcode scanner'),
    0x00F: ('hid', 'a keyboard, mouse, or gamepad'),
    0x011: ('sensor', 'a sensor'),
    0x015: ('health', 'a heart-rate monitor'),
    0x016: ('health', 'a blood-pressure monitor'),
    0x019: ('wearable', 'a cycling sensor'),
    0x024: ('audio-personal', 'an audio device'),
    0x025: ('wearable', 'a wearable audio device'),
    0x026: ('home', 'a toy'),
    0x027: ('home', 'a robot'),
    0x031: ('vehicle', 'a vehicle device'),
  };
}

const bleUuid16Class = <int, String>{
  0x1802: 'Tag-ImmAlert',
  0x1808: 'Health-Glucose',
  0x1809: 'Health-Thermom',
  0x180D: 'Wearable-HeartRate',
  0x1810: 'Health-BP',
  0x1812: 'Input-HID',
  0x1814: 'Wearable-RSC',
  0x1815: 'Home-AutoIO',
  0x1816: 'Wearable-CSC',
  0x1818: 'Wearable-CyclePwr',
  0x181A: 'Home-EnvSense',
  0x181B: 'Health-BodyComp',
  0x181D: 'Health-Scale',
  0x181F: 'Health-CGM',
  0x1821: 'Beacon-IndoorPos',
  0x1822: 'Health-PulseOx',
  0x1826: 'Health-FitMach',
  0x1827: 'Home-Mesh',
  0x1828: 'Home-Mesh',
  0x183A: 'Health-Insulin',
  0x183B: 'Home-BinSensor',
  0x183E: 'Wearable-ActivMon',
  0x1840: 'Health-HealthSns',
  0x1844: 'Audio-LE',
  0x1846: 'Audio-LE',
  0x184B: 'Phone-TelBearer',
  0x184E: 'Audio-LE',
  0x184F: 'Audio-LE',
  0x1850: 'Audio-LE',
  0x1851: 'Audio-LE',
  0x1852: 'Audio-LE',
  0x1853: 'Audio-LE',
  0x1854: 'Audio-HearingAid',
  0x1856: 'Audio-Auracast',
  0x1857: 'Beacon-ESL',
  0x1858: 'Audio-GamingAud',
  0x1860: 'Vehicle-TPMS',
  0x3100: 'Camera-Raven',
  0x3101: 'Camera-Raven',
  0x3102: 'Camera-Raven',
  0x3200: 'Camera-Raven',
  0x3300: 'Camera-Raven',
  0x3400: 'Camera-Raven',
  0x3500: 'Camera-Raven',
  0xFC25: 'Beacon-Trackonomy',
  0xFC2C: 'Camera-Verkada',
  0xFC30: 'Camera-Insta360',
  0xFC31: 'Vehicle-Ford',
  0xFC39: 'Audio-Harman',
  0xFC3D: 'Beacon-Reelables',
  0xFC4A: 'Audio-Shokz',
  0xFC55: 'Vehicle-BYD',
  0xFC58: 'Beacon-Minew',
  0xFC69: 'Audio-Harman',
  0xFC6A: 'Audio-Sonos',
  0xFC6B: 'Audio-Sonos',
  0xFC7E: 'Audio-Harman',
  0xFC81: 'Radio-Axon',
  0xFC82: 'Wearable-Zwift',
  0xFC83: 'Health-iHealth',
  0xFC86: 'Vehicle-Samsara',
  0xFC87: 'Vehicle-Samsara',
  0xFC8F: 'Audio-Bose',
  0xFC90: 'Beacon-Wiliot',
  0xFC98: 'Home-Ruuvi',
  0xFCA6: 'Beacon-Hubble',
  0xFCA7: 'Beacon-Hubble',
  0xFCA8: 'Health-Medtronic',
  0xFCA9: 'Health-Medtronic',
  0xFCB0: 'Vehicle-Ford',
  0xFCB4: 'Health-Omron',
  0xFCB5: 'Health-Omron',
  0xFCB6: 'Health-Omron',
  0xFCB9: 'Home-Lumi',
  0xFCBF: 'Home-ASSA',
  0xFCC6: 'Beacon-Wiliot',
  0xFCCD: 'Audio-Marshall',
  0xFCD4: 'Health-Omron',
  0xFCDF: 'Vehicle-NIO',
  0xFCE1: 'Audio-Sony',
  0xFCE4: 'Vehicle-Samsara',
  0xFCE5: 'Vehicle-Samsara',
  0xFCF4: 'Lock-Schlage',
  0xFD03: 'Beacon-Quuppa',
  0xFD20: 'Health-GN',
  0xFD23: 'Lock-DOM',
  0xFD25: 'Home-Midea',
  0xFD26: 'Health-Novo',
  0xFD2A: 'Audio-Sony',
  0xFD3A: 'Camera-Verkada',
  0xFD3B: 'Camera-Verkada',
  0xFD3D: 'Home-SwitchBot',
  0xFD41: 'Home-Amazon',
  0xFD44: 'Tag-Apple',
  0xFD4D: 'Vehicle-70mai',
  0xFD4E: 'Vehicle-70mai',
  0xFD50: 'Home-Tuya',
  0xFD54: 'Home-Haier',
  0xFD56: 'Health-Resmed',
  0xFD57: 'Vehicle-Volvo',
  0xFD58: 'Vehicle-Volvo',
  0xFD59: 'Tag-Samsung',
  0xFD5A: 'Tag-Samsung',
  0xFD5E: 'Lock-Tapkey',
  0xFD5F: 'Wearable-Meta',
  0xFD6F: 'Phone-AppleGoog',
  0xFD71: 'Audio-GN',
  0xFD72: 'Input-Logitech',
  0xFD75: 'Health-Omnipod',
  0xFD76: 'Health-Omnipod',
  0xFD77: 'Wearable-Withings',
  0xFD78: 'Wearable-Withings',
  0xFD79: 'Health-Withings',
  0xFD7A: 'Health-Withings',
  0xFD7B: 'Home-Wyze',
  0xFD81: 'Lock-Sesame',
  0xFD82: 'Audio-Sony',
  0xFD84: 'Tag-Tile',
  0xFD86: 'Health-Abbott',
  0xFD8A: 'Home-Signify',
  0xFD8E: 'Radio-Motorola',
  0xFD93: 'Vehicle-BMW',
  0xFDA3: 'Radio-Inseego',
  0xFDA4: 'Radio-Inseego',
  0xFDA8: 'Vehicle-PSA',
  0xFDA9: 'Camera-Rhombus',
  0xFDAF: 'Beacon-Wiliot',
  0xFDB0: 'Wearable-Oura',
  0xFDB1: 'Wearable-Oura',
  0xFDC5: 'Vehicle-Automatic',
  0xFDC6: 'Health-Eli',
  0xFDC7: 'Health-Eli',
  0xFDCA: 'Vehicle-Fortin',
  0xFDCD: 'Home-Qingping',
  0xFDCE: 'Audio-Sennheiser',
  0xFDD2: 'Audio-Bose',
  0xFDDF: 'Audio-Harman',
  0xFDE1: 'Vehicle-Fortin',
  0xFDE3: 'Health-Abbott',
  0xFDF6: 'Audio-AIAIAI',
  0xFDFA: 'Health-Tandem',
  0xFDFB: 'Health-Tandem',
  0xFE00: 'Home-Amazon',
  0xFE03: 'Home-Amazon',
  0xFE04: 'Radio-Motorola',
  0xFE07: 'Audio-Sonos',
  0xFE0F: 'Home-Signify',
  0xFE15: 'Home-Amazon',
  0xFE1F: 'Wearable-Garmin',
  0xFE21: 'Audio-Bose',
  0xFE22: 'Health-Zoll',
  0xFE23: 'Health-Zoll',
  0xFE24: 'Home-August',
  0xFE2C: 'Audio-Google',
  0xFE30: 'Vehicle-VW',
  0xFE31: 'Vehicle-VW',
  0xFE33: 'Tag-Chipolo',
  0xFE3D: 'Health-BD',
  0xFE3E: 'Health-BD',
  0xFE45: 'Glasses-Snap',
  0xFE47: 'Vehicle-GM',
  0xFE48: 'Vehicle-GM',
  0xFE4A: 'Health-Omron',
  0xFE4B: 'Home-Signify',
  0xFE4C: 'Vehicle-VW',
  0xFE54: 'Wearable-Motiv',
  0xFE61: 'Input-Logitech',
  0xFE65: 'Tag-Chipolo',
  0xFE6A: 'Beacon-Kontakt',
  0xFE6B: 'Radio-Axon',
  0xFE6C: 'Radio-Axon',
  0xFE72: 'Health-Abbott',
  0xFE73: 'Health-Abbott',
  0xFE7A: 'Audio-Bragi',
  0xFE81: 'Health-Medtronic',
  0xFE82: 'Health-Medtronic',
  0xFE83: 'Beacon-Blue',
  0xFE87: 'Home-Yeelink',
  0xFE88: 'Lock-Salto',
  0xFE95: 'Home-Xiaomi',
  0xFE96: 'Vehicle-Tesla',
  0xFE97: 'Vehicle-Tesla',
  0xFE9A: 'Beacon-Estimote',
  0xFE9B: 'Vehicle-Samsara',
  0xFEA5: 'Camera-GoPro',
  0xFEA6: 'Camera-GoPro',
  0xFEAA: 'Beacon-Eddystone',
  0xFEAF: 'Home-Nest',
  0xFEB0: 'Home-Nest',
  0xFEB7: 'Wearable-Meta',
  0xFEB8: 'Wearable-Meta',
  0xFEBC: 'Health-Dexcom',
  0xFEBE: 'Audio-Bose',
  0xFED5: 'Audio-Plantronic',
  0xFED9: 'Wearable-Pebble',
  0xFEDC: 'Wearable-Jawbone',
  0xFEDD: 'Wearable-Jawbone',
  0xFEE0: 'Wearable-Huami',
  0xFEE1: 'Wearable-Huami',
  0xFEEC: 'Tag-Tile',
  0xFEED: 'Tag-Tile',
  0xFEEE: 'Wearable-Polar',
  0xFEEF: 'Wearable-Polar',
  0xFEFC: 'Beacon-Gimbal',
  0xFEFD: 'Beacon-Gimbal',
  0xFEFE: 'Audio-GN',
  0xFEFF: 'Audio-GN',
  0xFFFA: 'Drone-RemoteID',
};

const bleCompanyClass = <int, String>{
  0x0043: 'Drone-Parrot',
  0x0055: 'Audio-Plantronic',
  0x0057: 'Audio-Harman',
  0x0068: 'Vehicle-GM',
  0x006B: 'Wearable-Polar',
  0x0087: 'Wearable-Garmin',
  0x0089: 'Audio-Jabra',
  0x008A: 'Wearable-Jawbone',
  0x008C: 'Beacon-Gimbal',
  0x009E: 'Audio-Bose',
  0x009F: 'Wearable-Suunto',
  0x00BA: 'Health-Starkey',
  0x00C7: 'Beacon-Quuppa',
  0x00CC: 'Audio-Beats',
  0x00D0: 'Health-Dexcom',
  0x00D1: 'Wearable-Polar',
  0x0118: 'Beacon-Radius',
  0x011F: 'Vehicle-Volkswagen',
  0x012D: 'Audio-Sony',
  0x012E: 'Lock-ASSA',
  0x013B: 'Lock-Schlage',
  0x0157: 'Wearable-Huami',
  0x015D: 'Beacon-Estimote',
  0x0164: 'Home-Yeelight',
  0x0171: 'Home-Amazon',
  0x01AB: 'Wearable-Meta',
  0x01B5: 'Home-Nest',
  0x01D1: 'Lock-August',
  0x01DA: 'Input-Logitech',
  0x01F9: 'Health-Medtronic',
  0x01FC: 'Wearable-Wahoo',
  0x01FD: 'Beacon-Kontakt',
  0x020E: 'Health-Omron',
  0x022B: 'Vehicle-Tesla',
  0x0241: 'Audio-Bragi',
  0x0243: 'Health-Masimo',
  0x0275: 'Vehicle-Geotab',
  0x027D: 'Phone-Huawei',
  0x0293: 'Beacon-Blue',
  0x02B2: 'Wearable-Oura',
  0x02D5: 'Health-Omron',
  0x02E1: 'Home-Victron',
  0x02F2: 'Camera-GoPro',
  0x0304: 'Wearable-Oura',
  0x0309: 'Audio-Dolby',
  0x034D: 'Radio-Axon',
  0x0360: 'Health-Insulet',
  0x036F: 'Wearable-Motiv',
  0x038D: 'Health-ResMed',
  0x03BB: 'Health-Abbott',
  0x03C2: 'Glasses-Snap',
  0x03C5: 'Health-Abbott',
  0x03FF: 'Health-Withings',
  0x048E: 'Health-InPen',
  0x0494: 'Audio-Sennheiser',
  0x0499: 'Home-Ruuvi',
  0x04DE: 'Home-Lutron',
  0x04EC: 'Radio-Motorola',
  0x058E: 'Glasses-Meta',
  0x059D: 'Health-Tandem',
  0x05A7: 'Audio-Sonos',
  0x0600: 'Home-iRobot',
  0x060C: 'Glasses-Vuzix',
  0x060F: 'Home-Signify',
  0x0639: 'Beacon-Minew',
  0x065A: 'Audio-Marshall',
  0x067C: 'Tag-Tile',
  0x06B1: 'Home-SimpliSafe',
  0x06C1: 'Home-Alarm',
  0x06D5: 'Home-Sensirion',
  0x0723: 'Vehicle-Ford',
  0x075D: 'Camera-Rhombus',
  0x07C9: 'Audio-Skullcandy',
  0x07D0: 'Home-Tuya',
  0x07D6: 'Home-ecobee',
  0x0870: 'Camera-Wyze',
  0x08AA: 'Drone-DJI',
  0x08C0: 'Beacon-Accent',
  0x08C3: 'Tag-Chipolo',
  0x0909: 'Vehicle-70mai',
  0x0941: 'Vehicle-Rivian',
  0x094A: 'Wearable-Zwift',
  0x094F: 'Home-MikroTik',
  0x0977: 'Vehicle-Toyota',
  0x09C8: 'Camera-Flock',
  0x0A12: 'Home-Dyson',
  0x0B01: 'Home-Resideo',
  0x0B27: 'Home-Aqara',
  0x0B48: 'Vehicle-NIO',
  0x0B6B: 'Vehicle-Samsara',
  0x0BA9: 'Home-Shelly',
  0x0BDE: 'Lock-Yale',
  0x0C19: 'Camera-Arlo',
  0x0C34: 'Vehicle-BYD',
  0x0CAC: 'Audio-Shokz',
  0x0CC2: 'Audio-Anker',
  0x0CC4: 'Lock-ABUS',
  0x0D10: 'Radio-Kenwood',
  0x0D53: 'Glasses-Luxottica',
  0x0D5B: 'Camera-Axis',
  0x0DE8: 'Home-Vivint',
  0x0E25: 'Camera-Hikvision',
  0x0E7B: 'Wearable-Circular',
  0x0E9F: 'Health-Owlet',
  0x0EDE: 'Vehicle-Sony',
  0x10D7: 'Camera-Insta360',
  0x10F9: 'Glasses-Even',
  0x112B: 'Glasses-IXI',
};
