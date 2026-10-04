import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SkyPointerApp());
}

// ─────────────────────────────────────────────
//  REAL ASTRONOMY CALCULATOR
// ─────────────────────────────────────────────
class AstronomyCalculator {
  static Map<String, double> raDecToAltAz({
    required double raHours,
    required double decDeg,
    required double latDeg,
    required double lonDeg,
    required DateTime utcTime,
  }) {
    final jd = _julianDate(utcTime);
    final gmst = _gmst(jd);
    final lst = (gmst + lonDeg) % 360;
    final raDeg = raHours * 15.0;
    double ha = (lst - raDeg) % 360;
    if (ha < 0) ha += 360;
    final haR = ha * pi / 180;
    final decR = decDeg * pi / 180;
    final latR = latDeg * pi / 180;
    final sinAlt = sin(decR) * sin(latR) + cos(decR) * cos(latR) * cos(haR);
    final alt = asin(sinAlt) * 180 / pi;
    final cosAz = (sin(decR) - sin(alt * pi / 180) * sin(latR)) /
        (cos(alt * pi / 180) * cos(latR));
    double az = acos(cosAz.clamp(-1.0, 1.0)) * 180 / pi;
    if (sin(haR) > 0) az = 360 - az;
    return {'az': az % 360, 'alt': alt};
  }

  static double _julianDate(DateTime utc) {
    int y = utc.year;
    int m = utc.month;
    final d = utc.day + utc.hour / 24.0 + utc.minute / 1440.0 + utc.second / 86400.0;
    if (m <= 2) { y -= 1; m += 12; }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d + b - 1524.5;
  }

  static double _gmst(double jd) {
    final t = (jd - 2451545.0) / 36525.0;
    double gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0) +
        t * t * 0.000387933 - t * t * t / 38710000.0;
    return gmst % 360;
  }

  static Map<String, double> moonPosition({
    required double latDeg,
    required double lonDeg,
    required DateTime utcTime,
  }) {
    final jd = _julianDate(utcTime);
    double l0 = (218.316 + 13.176396 * (jd - 2451545.0)) % 360;
    double m  = (134.963 + 13.064993 * (jd - 2451545.0)) % 360;
    double f  = (93.272  + 13.229350 * (jd - 2451545.0)) % 360;
    final mR = m * pi / 180;
    final fR = f * pi / 180;
    double lon = l0 + 6.289 * sin(mR) - 1.274 * sin(2 * fR - mR) +
        0.658 * sin(2 * fR) - 0.214 * sin(2 * mR) - 0.186 * sin(mR);
    double lat = 5.128 * sin(fR) + 0.281 * sin(mR + fR) - 0.278 * sin(fR - mR);
    final lonR = lon * pi / 180;
    final latR = lat * pi / 180;
    const eps = 23.4397 * pi / 180;
    final raR  = atan2(sin(lonR) * cos(eps) - tan(latR) * sin(eps), cos(lonR));
    final decR = asin(sin(latR) * cos(eps) + cos(latR) * sin(eps) * sin(lonR));
    final raHours = (raR * 180 / pi / 15 + 24) % 24;
    final decDeg  = decR * 180 / pi;
    return raDecToAltAz(raHours: raHours, decDeg: decDeg, latDeg: latDeg, lonDeg: lonDeg, utcTime: utcTime);
  }
}

// ─────────────────────────────────────────────
//  NASA JPL HORIZONS API SERVICE
// ─────────────────────────────────────────────
//
//  Objects that get REAL-TIME positions from NASA:
//    Moon (301), Jupiter (599), Venus (299), Mars (499),
//    Saturn (699), Mercury (199), ISS (-125544)
//
//  Stars / Nebulae / Galaxies / Star Clusters keep using
//  AstronomyCalculator — their RA/Dec is effectively fixed.
//
//  On any network error the caller falls back to local math
//  transparently, so the app always shows something.
// ─────────────────────────────────────────────
class NasaHorizons {
  static const Map<String, String> _nasaIds = {
    'Moon'    : '301',
    'Jupiter' : '599',
    'Venus'   : '299',
    'Mars'    : '499',
    'Saturn'  : '699',
    'Mercury' : '199',
    'ISS'     : '-125544',
  };

  static bool supportsNasa(String objectName) =>
      _nasaIds.containsKey(objectName);

  static Future<Map<String, double>> getAltAz({
    required String objectName,
    required double lat,
    required double lon,
    required DateTime utcTime,
  }) async {
    final id = _nasaIds[objectName];
    if (id == null) throw Exception('No NASA ID for $objectName');

    // Horizons needs a window of at least 1 step.
    // Use current minute as START, +2 min as STOP, step = 1m → 3 rows, we use row 0.
    final start = _fmt(utcTime);
    final stop  = _fmt(utcTime.add(const Duration(minutes: 2)));

    // SITE_COORD: lon,lat,alt_km  — NO surrounding single quotes in the query string.
    // Horizons API expects them URL-encoded as plain values.
    // Horizons REQUIRES single quotes around SITE_COORD.
    // We build the URL manually so quotes appear as %27 (not double-encoded).
    final lonStr = lon.toStringAsFixed(4);
    final latStr = lat.toStringAsFixed(4);
    final siteCoord = '%27$lonStr,$latStr,0%27';   // %27 = single quote

    final urlStr =
        'https://ssd.jpl.nasa.gov/api/horizons.api'
        '?format=json'
        '&COMMAND=${Uri.encodeComponent(id)}'
        '&OBJ_DATA=NO'
        '&MAKE_EPHEM=YES'
        '&EPHEM_TYPE=OBSERVER'
        '&CENTER=coord%40399'
        '&COORD_TYPE=GEODETIC'
        '&SITE_COORD=$siteCoord'
        '&START_TIME=$start'
        '&STOP_TIME=$stop'
        '&STEP_SIZE=1m'
        '&QUANTITIES=4'
        '&ANG_FORMAT=DEG'
        '&SKIP_DAYLT=NO'
        '&EXTRA_PREC=YES';

    final uri = Uri.parse(urlStr);
    debugPrint('NASA Horizons URL: $uri');

    final response = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Horizons HTTP ${response.statusCode}: ${response.body.substring(0, 200)}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    // If Horizons returns an error field, surface it clearly
    if (body.containsKey('error')) {
      throw Exception('Horizons API error: ${body['error']}');
    }

    final result = body['result'] as String? ?? '';
    debugPrint('NASA raw snippet: ${result.length > 300 ? result.substring(0, 300) : result}');

    return _parseHorizonsResult(result);
  }

  // Date formatter → "YYYY-MM-DDTHH:MM"  (Horizons accepts ISO T-separator,
  // which avoids the space-in-URL problem entirely)
  static String _fmt(DateTime dt) {
    final d = dt.toUtc();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-${dd}T$hh:$mi';
  }

  // ── Parse $$SOE … $$EOE block ──────────────────────────────────
  //
  //  Row format (QUANTITIES=4, ANG_FORMAT=DEG, EXTRA_PREC=YES):
  //
  //   2026-Jun-19 18:00 *m  156.3271 +23.4812 ...
  //   col0=date  col1=time  col2=flag(optional)  col3=Az  col4=Alt
  //
  //  Strategy: scan columns left-to-right for first pair where
  //    v1 ∈ [0,360]  and  v2 ∈ [-90,+90]
  // ────────────────────────────────────────────────────────────────
  static Map<String, double> _parseHorizonsResult(String text) {
    final soeIdx = text.indexOf(r'$$SOE');
    final eoeIdx = text.indexOf(r'$$EOE');
    if (soeIdx == -1 || eoeIdx == -1) {
      // Log first 500 chars of result to help diagnose
      final snippet = text.length > 500 ? text.substring(0, 500) : text;
      throw Exception('Horizons: SOE/EOE markers not found. Response start: $snippet');
    }

    final dataBlock = text.substring(soeIdx + 5, eoeIdx).trim();
    final lines = dataBlock
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      throw Exception('Horizons: empty data block between SOE/EOE');
    }

    debugPrint('NASA data row: ${lines[0]}');

    final parts = lines[0].split(RegExp(r'\s+'));

    double? az, alt;
    for (int i = 0; i < parts.length - 1; i++) {
      // Strip leading + sign that Horizons sometimes adds to altitude
      final raw1 = parts[i].replaceFirst('+', '');
      final raw2 = parts[i + 1].replaceFirst('+', '');
      final v1 = double.tryParse(raw1);
      final v2 = double.tryParse(raw2);
      if (v1 != null && v2 != null &&
          v1 >= 0   && v1 <= 360 &&
          v2 >= -90 && v2 <= 90) {
        az  = v1;
        alt = v2;
        break;
      }
    }

    if (az == null || alt == null) {
      throw Exception('Horizons: could not parse Az/Alt. Row was: "${lines[0]}"');
    }

    return {'az': az, 'alt': alt};
  }
}

// ─────────────────────────────────────────────
//  THEME MODEL
// ─────────────────────────────────────────────
class SkyTheme {
  final String key, name, desc, emoji;
  final Color bg, card, accent, textPrimary, textSecondary, border;
  final Color bgGradStart, bgGradEnd;
  final bool useMono, lightTheme;
  const SkyTheme({
    required this.key, required this.name, required this.desc, required this.emoji,
    required this.bg, required this.card, required this.accent,
    required this.textPrimary, required this.textSecondary, required this.border,
    required this.bgGradStart, required this.bgGradEnd,
    this.useMono = false, this.lightTheme = false,
  });
}

const List<SkyTheme> allThemes = [
  SkyTheme(key:'synthwave',name:'Synthwave',desc:'Retro neon grid',emoji:'⚡',bg:Color(0xFF060008),card:Color(0xFF100018),accent:Color(0xFFFF40C8),textPrimary:Color(0xFFF0C8FF),textSecondary:Color(0xFF8040C0),border:Color(0xFF6010A0),bgGradStart:Color(0xFF1A0030),bgGradEnd:Color(0xFF060008),useMono:true),
  SkyTheme(key:'nebula',name:'Nebula',desc:'Deep cosmic field',emoji:'🌌',bg:Color(0xFF080010),card:Color(0xFF0E0018),accent:Color(0xFFC080FF),textPrimary:Color(0xFFE8D0FF),textSecondary:Color(0xFF7040B0),border:Color(0xFF3A1060),bgGradStart:Color(0xFF180030),bgGradEnd:Color(0xFF040008)),
  SkyTheme(key:'aurora',name:'Aurora',desc:'Northern lights',emoji:'🌿',bg:Color(0xFF020E08),card:Color(0xFF061410),accent:Color(0xFF40E878),textPrimary:Color(0xFFD0F8E8),textSecondary:Color(0xFF408060),border:Color(0xFF1A3020),bgGradStart:Color(0xFF002818),bgGradEnd:Color(0xFF020E08)),
  SkyTheme(key:'eclipse',name:'Eclipse',desc:'Blood moon drama',emoji:'🌑',bg:Color(0xFF050002),card:Color(0xFF0A0004),accent:Color(0xFFC02020),textPrimary:Color(0xFFF0C0C0),textSecondary:Color(0xFF904040),border:Color(0xFF3A0808),bgGradStart:Color(0xFF200006),bgGradEnd:Color(0xFF050002)),
  SkyTheme(key:'matrix',name:'Matrix',desc:'Digital cosmos',emoji:'◈',bg:Color(0xFF000800),card:Color(0xFF001006),accent:Color(0xFF00FF40),textPrimary:Color(0xFF80FFA0),textSecondary:Color(0xFF206030),border:Color(0xFF004020),bgGradStart:Color(0xFF001A08),bgGradEnd:Color(0xFF000800),useMono:true),
  SkyTheme(key:'luxe',name:'Luxe',desc:'Fine astronomy gold',emoji:'✦',bg:Color(0xFF080600),card:Color(0xFF100C04),accent:Color(0xFFC8A040),textPrimary:Color(0xFFF0E0B0),textSecondary:Color(0xFF907040),border:Color(0xFF4A3010),bgGradStart:Color(0xFF1A1200),bgGradEnd:Color(0xFF080600)),
  SkyTheme(key:'supernova',name:'Supernova',desc:'Stellar explosion energy',emoji:'💥',bg:Color(0xFF0A0200),card:Color(0xFF180800),accent:Color(0xFFFF5500),textPrimary:Color(0xFFFFD0A0),textSecondary:Color(0xFFA05020),border:Color(0xFF602010),bgGradStart:Color(0xFF280800),bgGradEnd:Color(0xFF0A0200)),
  SkyTheme(key:'ocean',name:'Ocean',desc:'Deep space blue depths',emoji:'🌊',bg:Color(0xFF000A14),card:Color(0xFF001828),accent:Color(0xFF00AAFF),textPrimary:Color(0xFFB0E0FF),textSecondary:Color(0xFF205878),border:Color(0xFF003858),bgGradStart:Color(0xFF001C30),bgGradEnd:Color(0xFF000A14)),
  SkyTheme(key:'arctic',name:'Arctic',desc:'Ice cold stargazing',emoji:'❄',bg:Color(0xFFF0F8FF),card:Color(0xFFE0F0FF),accent:Color(0xFF1080B0),textPrimary:Color(0xFF081828),textSecondary:Color(0xFF5080A0),border:Color(0xFFA0C8E0),bgGradStart:Color(0xFFD0E8F8),bgGradEnd:Color(0xFFF8FCFF),lightTheme:true),
  SkyTheme(key:'kawaii',name:'Kawaii',desc:'Pastel space dreams',emoji:'♡',bg:Color(0xFFFDF8FF),card:Color(0xFFF8F0FF),accent:Color(0xFFE060B0),textPrimary:Color(0xFF2A1A38),textSecondary:Color(0xFFA080A0),border:Color(0xFFE0C0E0),bgGradStart:Color(0xFFFFE8FF),bgGradEnd:Color(0xFFFDF8FF),lightTheme:true),
];

class ThemeNotifier extends ChangeNotifier {
  SkyTheme _current = allThemes[0];
  SkyTheme get current => _current;
  void setTheme(SkyTheme t) { _current = t; notifyListeners(); }
}
final themeNotifier = ThemeNotifier();

// ─────────────────────────────────────────────
//  CELESTIAL OBJECTS
// ─────────────────────────────────────────────
class CelestialObject {
  final String name, type, icon, description, distance, visibility, bestMonths, funFact, nasaFact;
  final double raHours, decDeg;
  bool isFavourite;
  CelestialObject({
    required this.name, required this.type, required this.icon,
    required this.description, required this.distance, required this.visibility,
    required this.bestMonths, required this.funFact, required this.nasaFact,
    required this.raHours, required this.decDeg,
    this.isFavourite = false,
  });

  Map<String, double> getPosition(double lat, double lon) {
    final utc = DateTime.now().toUtc();
    if (name == 'Moon') {
      return AstronomyCalculator.moonPosition(latDeg: lat, lonDeg: lon, utcTime: utc);
    }
    return AstronomyCalculator.raDecToAltAz(
      raHours: raHours, decDeg: decDeg, latDeg: lat, lonDeg: lon, utcTime: utc,
    );
  }
}

List<CelestialObject> celestialObjects = [
  CelestialObject(name:'Moon',type:'Satellite',icon:'🌙',description:'Earth\'s only natural satellite.',distance:'384,400 km',visibility:'★★★★★',bestMonths:'All year',funFact:'The Moon moves away from Earth at 3.8 cm per year!',nasaFact:'NASA\'s Artemis program aims to return humans to the Moon.',raHours:-1,decDeg:0),
  CelestialObject(name:'Jupiter',type:'Planet',icon:'♃',description:'The largest planet in our solar system.',distance:'628 million km',visibility:'★★★★',bestMonths:'Sep - Nov',funFact:'Jupiter\'s Great Red Spot is a storm larger than Earth!',nasaFact:'NASA\'s Juno spacecraft orbits Jupiter.',raHours:2.75,decDeg:15.5),
  CelestialObject(name:'Venus',type:'Planet',icon:'♀',description:'The brightest planet near sunrise/sunset.',distance:'261 million km',visibility:'★★★★★',bestMonths:'Mar - May',funFact:'Venus rotates backwards compared to most planets!',nasaFact:'A day on Venus is longer than its year.',raHours:4.2,decDeg:20.2),
  CelestialObject(name:'Mars',type:'Planet',icon:'♂',description:'The Red Planet with the tallest volcano.',distance:'225 million km',visibility:'★★★',bestMonths:'Oct - Dec',funFact:'Mars has Olympus Mons — tallest mountain in solar system!',nasaFact:'NASA\'s Perseverance rover is exploring Mars.',raHours:5.5,decDeg:24.3),
  CelestialObject(name:'Saturn',type:'Planet',icon:'♄',description:'The ringed planet — most beautiful in sky.',distance:'1.2 billion km',visibility:'★★★★',bestMonths:'Aug - Oct',funFact:'Saturn\'s rings are made of ice and rock particles.',nasaFact:'Saturn\'s rings span 282,000 km.',raHours:22.5,decDeg:-11.0),
  CelestialObject(name:'Mercury',type:'Planet',icon:'☿',description:'The smallest planet, closest to the Sun.',distance:'155 million km',visibility:'★★',bestMonths:'Mar, Sep',funFact:'Mercury has no atmosphere so it has no weather!',nasaFact:'A year on Mercury is just 88 Earth days.',raHours:3.5,decDeg:18.0),
  CelestialObject(name:'Sirius',type:'Star',icon:'⭐',description:'The brightest star in the night sky.',distance:'8.6 light years',visibility:'★★★★★',bestMonths:'Jan - Mar',funFact:'Sirius is actually a binary star system!',nasaFact:'Sirius is twice as massive as our Sun.',raHours:6.7525,decDeg:-16.7161),
  CelestialObject(name:'Polaris',type:'Star',icon:'🌟',description:'The North Star — always points north.',distance:'433 light years',visibility:'★★★',bestMonths:'All year',funFact:'Polaris is actually a triple star system!',nasaFact:'Polaris is used for celestial navigation.',raHours:2.5303,decDeg:89.2641),
  CelestialObject(name:'Betelgeuse',type:'Star',icon:'🔴',description:'A red supergiant in Orion constellation.',distance:'700 light years',visibility:'★★★★',bestMonths:'Dec - Feb',funFact:'Betelgeuse could explode as a supernova anytime!',nasaFact:'Betelgeuse would engulf Jupiter\'s orbit if at our Sun.',raHours:5.9194,decDeg:7.4069),
  CelestialObject(name:'Rigel',type:'Star',icon:'🔵',description:'Brightest blue star in Orion.',distance:'860 light years',visibility:'★★★★',bestMonths:'Dec - Feb',funFact:'Rigel shines 120,000 times brighter than our Sun!',nasaFact:'Rigel is one of the most luminous stars visible.',raHours:5.2422,decDeg:-8.2017),
  CelestialObject(name:'Orion Nebula',type:'Nebula',icon:'🌟',description:'Stellar nursery where new stars are born.',distance:'1,344 light years',visibility:'★★★',bestMonths:'Dec - Feb',funFact:'Contains over 700 stars in formation!',nasaFact:'Hubble captured stunning images of Orion Nebula.',raHours:5.5881,decDeg:-5.3911),
  CelestialObject(name:'Andromeda',type:'Galaxy',icon:'🌌',description:'Nearest galaxy — farthest naked eye object.',distance:'2.5 million light years',visibility:'★★',bestMonths:'Oct - Nov',funFact:'Andromeda will collide with Milky Way in 4 billion years!',nasaFact:'Andromeda contains over 1 trillion stars.',raHours:0.7122,decDeg:41.2692),
  CelestialObject(name:'Pleiades',type:'Star Cluster',icon:'✨',description:'The Seven Sisters in Taurus.',distance:'444 light years',visibility:'★★★★',bestMonths:'Nov - Feb',funFact:'There are actually 3,000 stars in Pleiades!',nasaFact:'The Pleiades cluster is only 100 million years old.',raHours:3.7900,decDeg:24.1167),
  CelestialObject(name:'ISS',type:'Space Station',icon:'🛸',description:'Brightest moving object in the sky.',distance:'408 km',visibility:'★★★★★',bestMonths:'All year',funFact:'ISS orbits Earth every 90 minutes at 28,000 km/h!',nasaFact:'ISS has been inhabited since November 2000.',raHours:0,decDeg:0),
];

// ─────────────────────────────────────────────
//  DARK SKY SPOTS
// ─────────────────────────────────────────────
class DarkSkySpot {
  final String name, description, quality;
  final double lat, lng;
  double distanceKm;
  DarkSkySpot({required this.name, required this.description, required this.quality, required this.lat, required this.lng, this.distanceKm = 0});
}

List<DarkSkySpot> darkSkySpots = [
  DarkSkySpot(name:'Bhimashankar Forest',description:'Dense forest, minimal light pollution',quality:'Excellent',lat:19.0728,lng:73.5392),
  DarkSkySpot(name:'Rajmachi Fort',description:'Historic hill fort with panoramic sky views',quality:'Very Good',lat:18.7581,lng:73.4027),
  DarkSkySpot(name:'Kas Plateau',description:'UNESCO heritage site with pristine dark skies',quality:'Excellent',lat:17.7209,lng:73.8220),
  DarkSkySpot(name:'Tamhini Ghat',description:'Scenic mountain road with low light pollution',quality:'Good',lat:18.4833,lng:73.3833),
  DarkSkySpot(name:'Harishchandragad',description:'Remote fort, among the darkest skies in Maharashtra',quality:'Excellent',lat:19.3897,lng:73.7781),
  DarkSkySpot(name:'Malshej Ghat',description:'Beautiful ghat with open valleys',quality:'Very Good',lat:19.2167,lng:73.7667),
  DarkSkySpot(name:'Torna Fort',description:'High altitude fort with minimal light pollution',quality:'Good',lat:18.2760,lng:73.6227),
];

// ─────────────────────────────────────────────
//  MOON PHASE
// ─────────────────────────────────────────────
Map<String, String> getMoonPhase() {
  final knownNewMoon = DateTime.utc(2000, 1, 6, 18, 14);
  final now = DateTime.now().toUtc();
  final daysSince = now.difference(knownNewMoon).inSeconds / 86400.0;
  const lunarCycle = 29.53058867;
  final age = daysSince % lunarCycle;
  if (age < 1.85)  return {'emoji':'🌑','name':'New Moon','desc':'Best night for stargazing!'};
  if (age < 7.38)  return {'emoji':'🌒','name':'Waxing Crescent','desc':'Slim crescent visible after sunset'};
  if (age < 9.22)  return {'emoji':'🌓','name':'First Quarter','desc':'Half moon visible in the evening'};
  if (age < 14.77) return {'emoji':'🌔','name':'Waxing Gibbous','desc':'Moon getting brighter each night'};
  if (age < 16.61) return {'emoji':'🌕','name':'Full Moon','desc':'Brightest night — harder to see stars'};
  if (age < 22.15) return {'emoji':'🌖','name':'Waning Gibbous','desc':'Moon rising later each night'};
  if (age < 23.99) return {'emoji':'🌗','name':'Last Quarter','desc':'Half moon visible before sunrise'};
  return {'emoji':'🌘','name':'Waning Crescent','desc':'Dark skies returning soon!'};
}

// ─────────────────────────────────────────────
//  TIME-BASED GREETINGS
// ─────────────────────────────────────────────
Map<String, String> getGreeting() {
  final h = DateTime.now().hour;
  if (h >= 5  && h < 9)  return {'greeting':'Good Morning ☀️','message':'Venus might still be glowing on the eastern horizon!'};
  if (h >= 9  && h < 12) return {'greeting':'Good Morning ☀️','message':'Perfect time to plan your stargazing session for tonight!'};
  if (h >= 12 && h < 15) return {'greeting':'Good Afternoon 🌤️','message':'The Sun is king right now — but the stars are waiting! 🌟'};
  if (h >= 15 && h < 18) return {'greeting':'Good Afternoon 🌤️','message':'Just a few hours until the sky opens up for you! 🔭'};
  if (h >= 18 && h < 20) return {'greeting':'Good Evening 🌅','message':'Golden hour! Venus and Jupiter may be visible at the horizon.'};
  if (h >= 20 && h < 23) return {'greeting':'Good Evening 🌌','message':'Prime stargazing time! Head outside and explore the cosmos! 🚀'};
  return {'greeting':'Good Night 🌙','message':'Deep night — perfect conditions for spotting the Milky Way! ✨'};
}

// ─────────────────────────────────────────────
//  APP ROOT
// ─────────────────────────────────────────────
class SkyPointerApp extends StatefulWidget {
  const SkyPointerApp({super.key});
  @override
  State<SkyPointerApp> createState() => _SkyPointerAppState();
}

class _SkyPointerAppState extends State<SkyPointerApp> {
  @override
  void initState() { super.initState(); themeNotifier.addListener(() => setState(() {})); }

  @override
  Widget build(BuildContext context) {
    final t = themeNotifier.current;
    return MaterialApp(
      title: 'SkyPointer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: t.lightTheme ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: t.bg,
        colorScheme: ColorScheme(
          brightness: t.lightTheme ? Brightness.light : Brightness.dark,
          primary: t.accent, onPrimary: t.lightTheme ? Colors.white : t.bg,
          secondary: t.accent, onSecondary: t.lightTheme ? Colors.white : t.bg,
          error: Colors.redAccent, onError: Colors.white,
          surface: t.card, onSurface: t.textPrimary,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ─────────────────────────────────────────────
//  SPLASH SCREEN
// ─────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late AnimationController _starCtrl, _logoCtrl, _exitCtrl;
  late Animation<double> _starFade, _logoScale, _logoFade, _tagFade, _exitFade;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _starCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _exitCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _starFade  = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_starCtrl, curve:Curves.easeIn));
    _logoScale = Tween<double>(begin:0.6,end:1).animate(CurvedAnimation(parent:_logoCtrl, curve:Curves.elasticOut));
    _logoFade  = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_logoCtrl, curve:const Interval(0,0.5,curve:Curves.easeIn)));
    _tagFade   = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_logoCtrl, curve:const Interval(0.5,1.0,curve:Curves.easeIn)));
    _exitFade  = Tween<double>(begin:1,end:0).animate(CurvedAnimation(parent:_exitCtrl, curve:Curves.easeOut));
    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 200));
    _starCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 600));
    _logoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 2800));
    _exitCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      Navigator.pushReplacement(context, PageRouteBuilder(
        pageBuilder: (_,__,___) => const MainShell(),
        transitionsBuilder: (_,anim,__,child) => FadeTransition(opacity:anim, child:child),
        transitionDuration: const Duration(milliseconds: 500),
      ));
    }
  }

  @override
  void dispose() { _starCtrl.dispose(); _logoCtrl.dispose(); _exitCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: const Color(0xFF04020E),
      body: FadeTransition(
        opacity: _exitFade,
        child: Stack(children: [
          FadeTransition(opacity:_starFade, child:CustomPaint(painter:_StarfieldPainter(_rng), size:size)),
          Container(decoration:const BoxDecoration(gradient:RadialGradient(center:Alignment.center, radius:0.8, colors:[Color(0x442A1060),Color(0x00000000)]))),
          Center(child: Column(mainAxisAlignment:MainAxisAlignment.center, children: [
            ScaleTransition(scale:_logoScale, child:FadeTransition(opacity:_logoFade,
                child:Container(width:110, height:110,
                    decoration:BoxDecoration(shape:BoxShape.circle, color:const Color(0xFF0A0820),
                        border:Border.all(color:const Color(0xFF7B61FF).withOpacity(0.6), width:2),
                        boxShadow:[BoxShadow(color:const Color(0xFF7B61FF).withOpacity(0.4), blurRadius:30, spreadRadius:8), BoxShadow(color:const Color(0xFF00D4FF).withOpacity(0.2), blurRadius:50, spreadRadius:15)]),
                    child:const Center(child:Text('🔭', style:TextStyle(fontSize:52)))))),
            const SizedBox(height:32),
            FadeTransition(opacity:_logoFade, child:ScaleTransition(scale:_logoScale,
                child:ShaderMask(shaderCallback:(bounds)=>const LinearGradient(colors:[Color(0xFF7B61FF),Color(0xFF00D4FF)]).createShader(bounds),
                    child:const Text('SkyPointer', style:TextStyle(fontSize:44, fontWeight:FontWeight.bold, color:Colors.white, letterSpacing:3))))),
            const SizedBox(height:12),
            FadeTransition(opacity:_tagFade, child:const Text('NAVIGATE THE NIGHT SKY', style:TextStyle(color:Color(0xFF00D4FF), fontSize:12, letterSpacing:5, fontWeight:FontWeight.w300))),
            const SizedBox(height:60),
            FadeTransition(opacity:_tagFade, child:_LoadingDots()),
          ])),
        ]),
      ),
    );
  }
}

class _StarfieldPainter extends CustomPainter {
  final Random rng;
  _StarfieldPainter(this.rng);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (int i = 0; i < 150; i++) {
      paint.color = Colors.white.withOpacity(rng.nextDouble() * 0.7 + 0.2);
      canvas.drawCircle(Offset(rng.nextDouble()*size.width, rng.nextDouble()*size.height), rng.nextDouble()*1.5+0.3, paint);
    }
    final colors = [const Color(0xFF7B61FF), const Color(0xFF00D4FF), const Color(0xFFFF40C8)];
    for (int i = 0; i < 15; i++) {
      paint.color = colors[rng.nextInt(colors.length)].withOpacity(0.6);
      canvas.drawCircle(Offset(rng.nextDouble()*size.width, rng.nextDouble()*size.height), 1.2, paint);
    }
  }
  @override
  bool shouldRepaint(_StarfieldPainter old) => false;
}

class _LoadingDots extends StatefulWidget {
  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  int _dot = 0;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync:this, duration:const Duration(milliseconds:500))
      ..addListener(() { if (_ctrl.status==AnimationStatus.completed) { setState(()=>_dot=(_dot+1)%3); _ctrl.reset(); _ctrl.forward(); } })
      ..forward();
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Row(
      mainAxisAlignment:MainAxisAlignment.center,
      children:List.generate(3, (i)=>Container(
          margin:const EdgeInsets.symmetric(horizontal:4), width:6, height:6,
          decoration:BoxDecoration(shape:BoxShape.circle,
              color:i==_dot ? const Color(0xFF7B61FF) : const Color(0xFF7B61FF).withOpacity(0.25)))));
}

// ─────────────────────────────────────────────
//  THEMED BACKGROUND
// ─────────────────────────────────────────────
class ThemedBackground extends StatelessWidget {
  final SkyTheme theme;
  final Widget child;
  const ThemedBackground({super.key, required this.theme, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter, end:Alignment.bottomCenter, colors:[theme.bgGradStart, theme.bgGradEnd])),
    child:child,
  );
}

// ─────────────────────────────────────────────
//  MAIN SHELL
// ─────────────────────────────────────────────
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _idx = 0;
  Position? _userPosition;

  @override
  void initState() {
    super.initState();
    themeNotifier.addListener(() => setState(() {}));
    _loadFavs();
    _loadLocation();
  }

  Future<void> _loadFavs() async {
    final prefs = await SharedPreferences.getInstance();
    final favs = prefs.getStringList('favourites') ?? [];
    setState(() { for (var o in celestialObjects) o.isFavourite = favs.contains(o.name); });
  }

  Future<void> _loadLocation() async {
    try {
      bool ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) return;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      setState(() => _userPosition = pos);
      _updateDistances(pos);
    } catch (e) { debugPrint('GPS: $e'); }
  }

  void _updateDistances(Position pos) {
    for (var s in darkSkySpots) s.distanceKm = Geolocator.distanceBetween(pos.latitude, pos.longitude, s.lat, s.lng) / 1000;
    darkSkySpots.sort((a,b) => a.distanceKm.compareTo(b.distanceKm));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = themeNotifier.current;
    return Scaffold(
      backgroundColor: t.bgGradEnd,
      appBar: AppBar(
        backgroundColor: t.card.withOpacity(0.95), elevation: 0, automaticallyImplyLeading: false,
        title: _idx == 0
            ? ShaderMask(shaderCallback:(b)=>LinearGradient(colors:[t.accent,t.textPrimary]).createShader(b),
            child:Text('SkyPointer', style:TextStyle(fontSize:22, fontWeight:FontWeight.bold, color:Colors.white, letterSpacing:2, fontFamily:t.useMono?'monospace':null)))
            : Text(['SkyPointer','Navigate','Dark Sky','My Log','Favourites'][_idx], style:TextStyle(color:t.textPrimary, fontSize:18, fontWeight:FontWeight.bold)),
        actions: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder:(_)=>const ThemeScreen())),
            child: Container(
              margin:const EdgeInsets.only(right:12), padding:const EdgeInsets.symmetric(horizontal:10, vertical:6),
              decoration:BoxDecoration(color:t.accent.withOpacity(0.15), borderRadius:BorderRadius.circular(12), border:Border.all(color:t.accent.withOpacity(0.4))),
              child:Row(children:[Text(t.emoji, style:const TextStyle(fontSize:15)), const SizedBox(width:5), Text(t.name, style:TextStyle(color:t.accent, fontSize:11, fontWeight:FontWeight.bold))]),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _idx,
        children: [
          HomeBody(theme:t, position:_userPosition),
          NavigationBody(theme:t, userPosition:_userPosition),
          DarkSkyBody(theme:t, position:_userPosition, onRequestLocation:_loadLocation),
          ObservationLogBody(theme:t),
          FavouritesBody(theme:t, onRefresh:_loadFavs),
        ],
      ),
      bottomNavigationBar: Container(
        color: t.card.withOpacity(0.95),
        child: SafeArea(top:false, child:Container(height:60,
            decoration:BoxDecoration(border:Border(top:BorderSide(color:t.border.withOpacity(0.3), width:0.5))),
            child:Row(mainAxisAlignment:MainAxisAlignment.spaceAround, children:[
              _NavBtn('🏠','Home',0,_idx,t,()=>setState(()=>_idx=0)),
              _NavBtn('🔭','Navigate',1,_idx,t,()=>setState(()=>_idx=1)),
              _NavBtn('🗺️','Dark Sky',2,_idx,t,()=>setState(()=>_idx=2)),
              _NavBtn('📝','My Log',3,_idx,t,()=>setState(()=>_idx=3)),
              _NavBtn('⭐','Favs',4,_idx,t,()=>setState(()=>_idx=4)),
            ]))),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final String icon, label; final int idx, current; final SkyTheme theme; final VoidCallback onTap;
  const _NavBtn(this.icon, this.label, this.idx, this.current, this.theme, this.onTap);
  @override
  Widget build(BuildContext context) {
    final bool active = idx==current;
    return GestureDetector(onTap:onTap,
        child:Container(padding:const EdgeInsets.symmetric(horizontal:12, vertical:6),
            decoration:BoxDecoration(color:active?theme.accent.withOpacity(0.15):Colors.transparent, borderRadius:BorderRadius.circular(10)),
            child:Column(mainAxisSize:MainAxisSize.min, children:[
              Text(icon, style:const TextStyle(fontSize:20)),
              const SizedBox(height:1),
              Text(label, style:TextStyle(fontSize:9, color:active?theme.accent:theme.textSecondary, fontWeight:active?FontWeight.bold:FontWeight.normal)),
            ])));
  }
}

// ─────────────────────────────────────────────
//  HOME BODY
// ─────────────────────────────────────────────
class HomeBody extends StatelessWidget {
  final SkyTheme theme; final Position? position;
  const HomeBody({super.key, required this.theme, this.position});

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final moon = getMoonPhase();
    final greeting = getGreeting();
    final tonight = celestialObjects.where((o)=>o.visibility.length>=4).take(3).toList();
    final locStr = position!=null ? '${position!.latitude.toStringAsFixed(2)}°N, ${position!.longitude.toStringAsFixed(2)}°E' : 'Locating...';

    return ThemedBackground(theme:t, child:SingleChildScrollView(padding:const EdgeInsets.all(16),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
          Text(greeting['greeting']!, style:TextStyle(color:t.textSecondary, fontSize:14, fontWeight:FontWeight.w500)),
          const SizedBox(height:4),
          Text(greeting['message']!, style:TextStyle(color:t.textPrimary, fontSize:16, fontWeight:FontWeight.bold, height:1.3)),
          const SizedBox(height:20),

          Container(width:double.infinity, padding:const EdgeInsets.all(18),
              decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(18), border:Border.all(color:t.accent.withOpacity(0.35))),
              child:Row(children:[
                Text(moon['emoji']!, style:const TextStyle(fontSize:52)),
                const SizedBox(width:16),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                  Text("Tonight's Moon", style:TextStyle(color:t.textSecondary, fontSize:11, letterSpacing:1)),
                  const SizedBox(height:4),
                  Text(moon['name']!, style:TextStyle(color:t.textPrimary, fontSize:20, fontWeight:FontWeight.bold)),
                  Text(moon['desc']!, style:TextStyle(color:t.accent, fontSize:12)),
                ])),
              ])),
          const SizedBox(height:16),

          Text('BEST TONIGHT', style:TextStyle(color:t.accent, fontSize:11, fontWeight:FontWeight.bold, letterSpacing:2)),
          const SizedBox(height:10),
          Row(children:[for(int i=0;i<tonight.length;i++)...[
            Expanded(child:Container(padding:const EdgeInsets.all(14),
                decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:t.border.withOpacity(0.3))),
                child:Column(children:[Text(tonight[i].icon, style:const TextStyle(fontSize:26)), const SizedBox(height:6),
                  Text(tonight[i].name, style:TextStyle(color:t.textPrimary, fontSize:11, fontWeight:FontWeight.bold), textAlign:TextAlign.center, overflow:TextOverflow.ellipsis),
                  Text(tonight[i].visibility, style:TextStyle(color:t.accent, fontSize:10)),
                ]))),
            if(i<tonight.length-1) const SizedBox(width:8),
          ]]),
          const SizedBox(height:16),

          Row(children:[
            Expanded(child:_Box('📍','Location', position!=null?locStr:'No GPS', t)),
            const SizedBox(width:10),
            Expanded(child:_Box('🌡️','Sky Quality','Moderate',t)),
            const SizedBox(width:10),
            Expanded(child:_Box('🔭','Objects','${celestialObjects.length}',t)),
          ]),
          const SizedBox(height:16),

          Container(width:double.infinity, padding:const EdgeInsets.all(16),
              decoration:BoxDecoration(color:t.accent.withOpacity(0.1), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.accent.withOpacity(0.25))),
              child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                Text('💡 SPACE FACT OF THE DAY', style:TextStyle(color:t.accent, fontSize:10, fontWeight:FontWeight.bold, letterSpacing:2)),
                const SizedBox(height:8),
                Text(celestialObjects[DateTime.now().day%celestialObjects.length].funFact, style:TextStyle(color:t.textPrimary, fontSize:13, height:1.6)),
              ])),
          const SizedBox(height:16),

          Container(width:double.infinity, padding:const EdgeInsets.all(16),
              decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.border.withOpacity(0.3))),
              child:Row(mainAxisAlignment:MainAxisAlignment.spaceAround, children:[
                _Stat('${celestialObjects.where((o)=>o.type=="Planet").length}','Planets',t),
                _Stat('${celestialObjects.where((o)=>o.type=="Star").length}','Stars',t),
                _Stat('${celestialObjects.where((o)=>o.type!="Planet"&&o.type!="Star").length}','Others',t),
                _Stat('${celestialObjects.where((o)=>o.isFavourite).length}','Saved',t),
              ])),
          const SizedBox(height:20),
        ])));
  }
}

class _Box extends StatelessWidget {
  final String icon,label,value; final SkyTheme t;
  const _Box(this.icon, this.label, this.value, this.t);
  @override
  Widget build(BuildContext context) => Container(padding:const EdgeInsets.all(10),
      decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(12), border:Border.all(color:t.border.withOpacity(0.3))),
      child:Column(children:[Text(icon, style:const TextStyle(fontSize:18)), const SizedBox(height:3),
        Text(value, style:TextStyle(color:t.textPrimary, fontSize:10, fontWeight:FontWeight.bold), overflow:TextOverflow.ellipsis),
        Text(label, style:TextStyle(color:t.textSecondary, fontSize:9))]));
}

class _Stat extends StatelessWidget {
  final String v,l; final SkyTheme t;
  const _Stat(this.v, this.l, this.t);
  @override
  Widget build(BuildContext context) => Column(children:[
    Text(v, style:TextStyle(color:t.accent, fontSize:22, fontWeight:FontWeight.bold)),
    Text(l, style:TextStyle(color:t.textSecondary, fontSize:10))]);
}

// ─────────────────────────────────────────────
//  NAVIGATION BODY
// ─────────────────────────────────────────────
class NavigationBody extends StatefulWidget {
  final SkyTheme theme;
  final Position? userPosition;
  const NavigationBody({super.key, required this.theme, this.userPosition});
  @override
  State<NavigationBody> createState() => _NavigationBodyState();
}

class _NavigationBodyState extends State<NavigationBody> with SingleTickerProviderStateMixin {
  CelestialObject sel = celestialObjects[0];
  double currentAz = 0, currentAlt = 0;
  double targetAz = 0, targetAlt = 0;
  String gText = 'Select an object to begin';
  Color gColor = Colors.grey;
  String gIcon = '🎯';
  final FlutterTts _tts = FlutterTts();
  late AnimationController _pulse;
  final double threshold = 3.0;
  Timer? _posTimer;

  // BLE fields
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription? _scanSub;
  StreamSubscription? _dataSub;
  String _btStatus = 'Disconnected';
  bool _isScanning = false;

  static const String SERVICE_UUID        = '12345678-1234-1234-1234-123456789abc';
  static const String CHARACTERISTIC_UUID = 'abcd1234-ab12-ab12-ab12-abcdef123456';

  // NASA API status — shown in the target bar subtitle
  bool _usingNasa    = false;   // true  → last position came from NASA
  bool _nasaFetching = false;   // true  → API call in flight

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('en-US'); _tts.setSpeechRate(0.45);
    _pulse = AnimationController(vsync:this, duration:const Duration(seconds:2))..repeat(reverse:true);
    _updateTargetPosition();
    _posTimer = Timer.periodic(const Duration(seconds: 60), (_) => _updateTargetPosition());
  }

  // ── Fetch target Az/Alt ──────────────────────────────────────────
  //  For planets, Moon, ISS  → try NASA JPL Horizons first.
  //  For stars/nebulae/etc   → always use local AstronomyCalculator.
  //  On any NASA failure     → silently fall back to local math.
  // ────────────────────────────────────────────────────────────────
  Future<void> _updateTargetPosition() async {
    final pos = widget.userPosition;
    final lat = pos?.latitude  ?? 18.5204;   // default: Pune
    final lon = pos?.longitude ?? 73.8567;
    final utc = DateTime.now().toUtc();

    if (NasaHorizons.supportsNasa(sel.name)) {
      // ── Try NASA API ──
      setState(() => _nasaFetching = true);
      try {
        final result = await NasaHorizons.getAltAz(
          objectName: sel.name,
          lat: lat,
          lon: lon,
          utcTime: utc,
        );
        if (mounted) {
          setState(() {
            targetAz      = result['az']!;
            targetAlt     = result['alt']!;
            _usingNasa    = true;
            _nasaFetching = false;
          });
        }
      } catch (e) {
        // NASA failed — fall back to local math silently
        debugPrint('NASA Horizons error for ${sel.name}: $e');
        final result = sel.getPosition(lat, lon);
        if (mounted) {
          setState(() {
            targetAz      = result['az']!;
            targetAlt     = result['alt']!;
            _usingNasa    = false;
            _nasaFetching = false;
          });
        }
      }
    } else {
      // ── Stars / nebulae / galaxies — local math only ──
      final result = sel.getPosition(lat, lon);
      if (mounted) {
        setState(() {
          targetAz      = result['az']!;
          targetAlt     = result['alt']!;
          _usingNasa    = false;
          _nasaFetching = false;
        });
      }
    }

    if (gText != 'Select an object to begin') _updateGuidance();
  }

  @override
  void didUpdateWidget(NavigationBody old) {
    super.didUpdateWidget(old);
    if (old.userPosition == null && widget.userPosition != null) {
      _updateTargetPosition();
    }
  }

  Future<void> _startScan() async {
    setState(() { _isScanning=true; _btStatus='Scanning...'; });
    await FlutterBluePlus.startScan(timeout:const Duration(seconds:6));
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.platformName == 'SkyPointer') {
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });
    await Future.delayed(const Duration(seconds:7));
    if (_device==null && mounted) setState(() { _isScanning=false; _btStatus='Device not found'; });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() { _btStatus='Connecting...'; _isScanning=false; });
    try {
      await device.connect(autoConnect:false);
      setState(() { _device=device; _btStatus='Connected ✓'; });
      _discoverServices(device);
    } catch (e) { setState(() => _btStatus='Connection failed'); }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    final services = await device.discoverServices();
    for (BluetoothService s in services) {
      if (s.uuid.toString().toLowerCase() == SERVICE_UUID) {
        for (BluetoothCharacteristic c in s.characteristics) {
          if (c.uuid.toString().toLowerCase() == CHARACTERISTIC_UUID) {
            _characteristic = c;
            await c.setNotifyValue(true);
            _dataSub = c.lastValueStream.listen((value) {
              if (value.isNotEmpty) _parseLine(String.fromCharCodes(value).trim());
            });
            setState(() => _btStatus='Streaming data ✓');
            break;
          }
        }
      }
    }
  }

  void _parseLine(String line) {
    final parts = line.split(',');
    if (parts.length == 2) {
      final az  = double.tryParse(parts[0].trim());
      final alt = double.tryParse(parts[1].trim());
      if (az != null && alt != null) {
        setState(() { currentAz=az; currentAlt=alt; });
        _updateGuidance();
      }
    }
  }

  Future<void> _disconnect() async {
    await _dataSub?.cancel();
    await _device?.disconnect();
    setState(() { _device=null; _characteristic=null; _btStatus='Disconnected'; });
  }

  void _updateGuidance() {
    final t = widget.theme;
    double dAz  = targetAz - currentAz;
    double dAlt = targetAlt - currentAlt;
    if (dAz >  180) dAz -= 360;
    if (dAz < -180) dAz += 360;
    String g; Color c; String icon;
    if (dAz.abs() < threshold && dAlt.abs() < threshold) {
      g='TARGET ALIGNED!'; c=Colors.greenAccent; icon='✅';
      HapticFeedback.heavyImpact();
      _tts.speak('Aligned! You are pointing at ${sel.name}');
    } else if (dAz.abs() > dAlt.abs()) {
      if (dAz>0) { g='Move RIGHT  →'; c=t.accent; icon='➡️'; }
      else        { g='←  Move LEFT'; c=t.accent; icon='⬅️'; }
    } else {
      if (dAlt>0) { g='Move UP  ↑'; c=t.textPrimary; icon='⬆️'; }
      else         { g='↓  Move DOWN'; c=t.textPrimary; icon='⬇️'; }
    }
    setState(() { gText=g; gColor=c; gIcon=icon; });
  }

  Future<void> _logObservation() async {
    final noteCtrl = TextEditingController();
    final t = widget.theme;
    await showDialog(context:context, builder:(_)=>AlertDialog(
      backgroundColor:t.card,
      title:Text('Log ${sel.name}', style:TextStyle(color:t.textPrimary, fontWeight:FontWeight.bold)),
      content:Column(mainAxisSize:MainAxisSize.min, children:[
        Text('Add a note:', style:TextStyle(color:t.textSecondary, fontSize:13)),
        const SizedBox(height:12),
        TextField(controller:noteCtrl, style:TextStyle(color:t.textPrimary), maxLines:3,
            decoration:InputDecoration(hintText:'e.g. Saw it clearly through binoculars!', hintStyle:TextStyle(color:t.textSecondary),
                filled:true, fillColor:t.bg, border:OutlineInputBorder(borderRadius:BorderRadius.circular(12), borderSide:BorderSide(color:t.border.withOpacity(0.4))))),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(context), child:Text('Cancel', style:TextStyle(color:t.textSecondary))),
        TextButton(onPressed:() async {
          Navigator.pop(context);
          final prefs = await SharedPreferences.getInstance();
          final logs  = prefs.getStringList('logs') ?? [];
          final now   = DateTime.now();
          final note  = noteCtrl.text.isEmpty ? 'Observed via SkyPointer' : noteCtrl.text;
          logs.add('${sel.name}|${sel.icon}|${sel.type}|${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2,'0')}|$note');
          await prefs.setStringList('logs', logs);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${sel.name} logged! 📝'), backgroundColor:t.card));
        }, child:Text('Save', style:TextStyle(color:t.accent, fontWeight:FontWeight.bold))),
      ],
    ));
  }

  Future<void> _toggleFav() async {
    final prefs = await SharedPreferences.getInstance();
    final favs  = prefs.getStringList('favourites') ?? [];
    setState(() { sel.isFavourite=!sel.isFavourite; if(sel.isFavourite) favs.add(sel.name); else favs.remove(sel.name); });
    await prefs.setStringList('favourites', favs);
  }

  @override
  void dispose() { _posTimer?.cancel(); _pulse.dispose(); _tts.stop(); _scanSub?.cancel(); _dataSub?.cancel(); _device?.disconnect(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    double dAz  = (targetAz - currentAz).abs();
    if (dAz > 180) dAz = 360 - dAz;
    double dAlt = (targetAlt - currentAlt).abs();
    double alignment = 1 - ((dAz + dAlt) / 180).clamp(0.0, 1.0);

    return ThemedBackground(theme:t, child:SingleChildScrollView(padding:const EdgeInsets.all(16),
        child:Column(children:[

          // Target bar
          Container(padding:const EdgeInsets.symmetric(horizontal:16, vertical:12),
              decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:t.border.withOpacity(0.3))),
              child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
                Row(children:[
                  Text(sel.icon, style:const TextStyle(fontSize:24)),
                  const SizedBox(width:10),
                  Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                    Text('TARGET', style:TextStyle(color:t.textSecondary, fontSize:9, letterSpacing:2)),
                    Text(sel.name, style:TextStyle(color:t.textPrimary, fontSize:16, fontWeight:FontWeight.bold)),
                    Row(children:[
                      if (_nasaFetching) ...[
                        SizedBox(width:8, height:8, child:CircularProgressIndicator(strokeWidth:1.5, color:t.accent)),
                        const SizedBox(width:4),
                        Text('Fetching NASA...', style:TextStyle(color:t.accent, fontSize:9)),
                      ] else if (_usingNasa) ...[
                        Icon(Icons.satellite_alt, size:9, color:Colors.greenAccent),
                        const SizedBox(width:3),
                        Text('NASA JPL Horizons ✓', style:TextStyle(color:Colors.greenAccent, fontSize:9, fontWeight:FontWeight.bold)),
                      ] else ...[
                        Icon(Icons.calculate_outlined, size:9, color:t.textSecondary),
                        const SizedBox(width:3),
                        Text('Local Calculation', style:TextStyle(color:t.textSecondary, fontSize:9)),
                      ],
                    ]),
                  ]),
                ]),
                Row(children:[
                  GestureDetector(onTap:_toggleFav,
                      child:Icon(sel.isFavourite?Icons.star:Icons.star_border, color:sel.isFavourite?Colors.amber:t.textSecondary, size:22)),
                  const SizedBox(width:8),
                  GestureDetector(
                    onTap: _device==null ? _startScan : _disconnect,
                    child:Container(padding:const EdgeInsets.symmetric(horizontal:10, vertical:6),
                        decoration:BoxDecoration(
                            color:_device!=null?Colors.green.withOpacity(0.15):t.accent.withOpacity(0.1),
                            borderRadius:BorderRadius.circular(10),
                            border:Border.all(color:_device!=null?Colors.greenAccent:t.accent.withOpacity(0.4))),
                        child:Row(children:[
                          _isScanning
                              ? const SizedBox(width:12, height:12, child:CircularProgressIndicator(strokeWidth:2))
                              : Icon(Icons.bluetooth, color:_device!=null?Colors.greenAccent:t.accent, size:14),
                          const SizedBox(width:5),
                          Text(_btStatus, style:TextStyle(color:_device!=null?Colors.greenAccent:t.accent, fontSize:9, fontWeight:FontWeight.bold)),
                        ])),
                  ),
                ]),
              ])),
          const SizedBox(height:14),

          Row(children:[
            Expanded(child:_DCard('TARGET',  targetAz,  targetAlt,  t.accent,      t)),
            const SizedBox(width:12),
            Expanded(child:_DCard('CURRENT', currentAz, currentAlt, t.textPrimary, t)),
          ]),
          const SizedBox(height:20),

          AnimatedBuilder(animation:_pulse, builder:(_,__)=>Container(width:190, height:190,
              decoration:BoxDecoration(shape:BoxShape.circle,
                  border:Border.all(color:gColor.withOpacity(0.3+0.3*_pulse.value), width:3),
                  boxShadow:[BoxShadow(color:gColor.withOpacity(0.08+0.12*_pulse.value), blurRadius:25, spreadRadius:8)]),
              child:Stack(alignment:Alignment.center, children:[
                SizedBox(width:170, height:170, child:CircularProgressIndicator(value:alignment, strokeWidth:8, backgroundColor:t.card.withOpacity(0.5), valueColor:AlwaysStoppedAnimation(gColor))),
                Column(mainAxisAlignment:MainAxisAlignment.center, children:[
                  Text(gIcon, style:const TextStyle(fontSize:34)),
                  const SizedBox(height:4),
                  Text('${(alignment*100).toInt()}%', style:TextStyle(color:gColor, fontSize:22, fontWeight:FontWeight.bold)),
                  Text('aligned', style:TextStyle(color:t.textSecondary, fontSize:11)),
                ]),
              ]))),
          const SizedBox(height:16),

          Container(width:double.infinity, padding:const EdgeInsets.symmetric(vertical:16),
              decoration:BoxDecoration(borderRadius:BorderRadius.circular(16), color:t.card.withOpacity(0.9), border:Border.all(color:gColor.withOpacity(0.4))),
              child:Text(gText, textAlign:TextAlign.center, style:TextStyle(color:gColor, fontSize:20, fontWeight:FontWeight.bold, letterSpacing:1, fontFamily:t.useMono?'monospace':null))),
          const SizedBox(height:10),

          Row(mainAxisAlignment:MainAxisAlignment.center, children:[
            _Chip('Az: ${dAz.toStringAsFixed(1)}°', dAz<3, t),
            const SizedBox(width:10),
            _Chip('Alt: ${dAlt.toStringAsFixed(1)}°', dAlt<3, t),
          ]),
          const SizedBox(height:16),

          Row(children:[
            Expanded(child:_Btn('SELECT', Icons.explore, t, () async {
              final r = await Navigator.push(context, MaterialPageRoute(builder:(_)=>const ObjectSelectionScreen()));
              if (r is CelestialObject) {
                setState(() { sel=r; gText='Calculating...'; });
                _updateTargetPosition();
              }
            })),
            const SizedBox(width:10),
            Expanded(child:_Btn('INFO', Icons.info_outline, t, ()=>Navigator.push(context, MaterialPageRoute(builder:(_)=>ObjectInfoScreen(object:sel, onFav:_toggleFav))))),
          ]),
          const SizedBox(height:10),
          Row(children:[
            Expanded(child:_Btn('🔊 SPEAK', Icons.volume_up, t, ()=>_tts.speak(gText))),
            const SizedBox(width:10),
            Expanded(child:_Btn('📝 LOG IT', Icons.book_outlined, t, _logObservation)),
          ]),
          const SizedBox(height:20),
        ])));
  }
}

class _DCard extends StatelessWidget {
  final String title; final double az,alt; final Color color; final SkyTheme t;
  const _DCard(this.title, this.az, this.alt, this.color, this.t);
  @override
  Widget build(BuildContext context) => Container(padding:const EdgeInsets.all(14),
      decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:color.withOpacity(0.3))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
        Text(title, style:TextStyle(color:color, fontSize:10, fontWeight:FontWeight.bold, letterSpacing:2)),
        const SizedBox(height:8),
        Text('Az: ${az.toStringAsFixed(1)}°',  style:TextStyle(color:t.textPrimary, fontSize:13)),
        const SizedBox(height:3),
        Text('Alt: ${alt.toStringAsFixed(1)}°', style:TextStyle(color:t.textPrimary, fontSize:13)),
      ]));
}

class _Chip extends StatelessWidget {
  final String label; final bool good; final SkyTheme t;
  const _Chip(this.label, this.good, this.t);
  @override
  Widget build(BuildContext context) => Container(
      padding:const EdgeInsets.symmetric(horizontal:14, vertical:7),
      decoration:BoxDecoration(
          color:good?Colors.green.withOpacity(0.15):t.card.withOpacity(0.9),
          borderRadius:BorderRadius.circular(20),
          border:Border.all(color:good?Colors.greenAccent:t.border.withOpacity(0.3))),
      child:Text(label, style:TextStyle(color:good?Colors.greenAccent:t.textSecondary, fontSize:12, fontWeight:FontWeight.w500)));
}

class _Btn extends StatelessWidget {
  final String label; final IconData icon; final SkyTheme t; final VoidCallback onTap;
  const _Btn(this.label, this.icon, this.t, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(onTap:onTap,
      child:Container(padding:const EdgeInsets.symmetric(vertical:14),
          decoration:BoxDecoration(borderRadius:BorderRadius.circular(14), color:t.accent.withOpacity(0.12), border:Border.all(color:t.accent.withOpacity(0.4))),
          child:Row(mainAxisAlignment:MainAxisAlignment.center, children:[Icon(icon, color:t.accent, size:16), const SizedBox(width:8), Text(label, style:TextStyle(color:t.accent, fontWeight:FontWeight.bold, fontSize:12))])));
}

// ─────────────────────────────────────────────
//  OBJECT SELECTION SCREEN
// ─────────────────────────────────────────────
class ObjectSelectionScreen extends StatefulWidget {
  const ObjectSelectionScreen({super.key});
  @override
  State<ObjectSelectionScreen> createState() => _ObjSelState();
}

class _ObjSelState extends State<ObjectSelectionScreen> {
  String _q=''; String _f='All';
  final filters=['All','Planet','Star','Nebula','Galaxy','Star Cluster','Space Station','Satellite'];
  @override
  void initState() { super.initState(); themeNotifier.addListener(()=>setState((){})); }

  @override
  Widget build(BuildContext context) {
    final t = themeNotifier.current;
    final list = celestialObjects.where((o)=>o.name.toLowerCase().contains(_q.toLowerCase())&&(_f=='All'||o.type==_f)).toList();
    return Scaffold(
      backgroundColor:t.bgGradEnd,
      appBar:AppBar(
        backgroundColor:t.card.withOpacity(0.95), elevation:0,
        leading:IconButton(icon:Icon(Icons.arrow_back_ios, color:t.textPrimary), onPressed:()=>Navigator.pop(context)),
        title:Text('Select Target', style:TextStyle(color:t.textPrimary, fontSize:18, fontWeight:FontWeight.bold)),
      ),
      body:ThemedBackground(theme:t, child:Column(children:[
        Padding(padding:const EdgeInsets.all(16),
            child:TextField(onChanged:(v)=>setState(()=>_q=v), style:TextStyle(color:t.textPrimary),
                decoration:InputDecoration(hintText:'Search objects...', hintStyle:TextStyle(color:t.textSecondary), prefixIcon:Icon(Icons.search, color:t.textSecondary, size:20),
                    filled:true, fillColor:t.card.withOpacity(0.9), contentPadding:const EdgeInsets.symmetric(vertical:12),
                    border:OutlineInputBorder(borderRadius:BorderRadius.circular(14), borderSide:BorderSide.none)))),
        SizedBox(height:36, child:ListView.builder(scrollDirection:Axis.horizontal, padding:const EdgeInsets.symmetric(horizontal:16), itemCount:filters.length,
            itemBuilder:(_,i){
              final a=_f==filters[i];
              return GestureDetector(onTap:()=>setState(()=>_f=filters[i]),
                  child:Container(margin:const EdgeInsets.only(right:8), padding:const EdgeInsets.symmetric(horizontal:14, vertical:6),
                      decoration:BoxDecoration(color:a?t.accent:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(20), border:Border.all(color:a?t.accent:t.border.withOpacity(0.3))),
                      child:Text(filters[i], style:TextStyle(color:a?(t.lightTheme?Colors.white:t.bg):t.textSecondary, fontSize:12, fontWeight:a?FontWeight.bold:FontWeight.normal))));
            })),
        const SizedBox(height:10),
        Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:16), itemCount:list.length,
            itemBuilder:(_,i){
              final o=list[i];
              return GestureDetector(
                onTap:()=>Navigator.pop(context,o),
                child:Container(margin:const EdgeInsets.only(bottom:10), padding:const EdgeInsets.all(14),
                    decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:t.accent.withOpacity(0.2))),
                    child:Row(children:[
                      Container(width:48, height:48, decoration:BoxDecoration(shape:BoxShape.circle, color:t.accent.withOpacity(0.1), border:Border.all(color:t.accent.withOpacity(0.3))),
                          child:Center(child:Text(o.icon, style:const TextStyle(fontSize:22)))),
                      const SizedBox(width:12),
                      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                        Row(children:[Text(o.name, style:TextStyle(color:t.textPrimary, fontSize:14, fontWeight:FontWeight.bold)),
                          if(o.isFavourite)...[const SizedBox(width:6), const Icon(Icons.star, color:Colors.amber, size:14)]]),
                        Text(o.type, style:TextStyle(color:t.accent, fontSize:11)),
                        Text('${o.visibility}  •  ${o.distance}', style:TextStyle(color:t.textSecondary, fontSize:11)),
                      ])),
                      Icon(Icons.chevron_right, color:t.textSecondary),
                    ])),
              );
            })),
      ])),
    );
  }
}

// ─────────────────────────────────────────────
//  OBJECT INFO SCREEN
// ─────────────────────────────────────────────
class ObjectInfoScreen extends StatefulWidget {
  final CelestialObject object; final VoidCallback? onFav;
  const ObjectInfoScreen({super.key, required this.object, this.onFav});
  @override
  State<ObjectInfoScreen> createState() => _ObjInfoState();
}

class _ObjInfoState extends State<ObjectInfoScreen> {
  final FlutterTts _tts = FlutterTts();
  @override
  void initState() { super.initState(); themeNotifier.addListener(()=>setState((){})); _tts.setLanguage('en-US'); }
  @override
  void dispose() { _tts.stop(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t=themeNotifier.current; final o=widget.object;
    return Scaffold(
      backgroundColor:t.bgGradEnd,
      appBar:AppBar(backgroundColor:t.card.withOpacity(0.95), elevation:0,
          leading:IconButton(icon:Icon(Icons.arrow_back_ios, color:t.textPrimary), onPressed:()=>Navigator.pop(context)),
          title:Text(o.name, style:TextStyle(color:t.textPrimary, fontWeight:FontWeight.bold)),
          actions:[
            IconButton(icon:Icon(o.isFavourite?Icons.star:Icons.star_border, color:Colors.amber), onPressed:(){ widget.onFav?.call(); setState((){}); }),
            IconButton(icon:Icon(Icons.volume_up, color:t.accent), onPressed:()=>_tts.speak('${o.name}. ${o.funFact}')),
          ]),
      body:ThemedBackground(theme:t, child:SingleChildScrollView(padding:const EdgeInsets.all(20), child:Column(children:[
        Container(width:110, height:110,
            decoration:BoxDecoration(shape:BoxShape.circle, color:t.card.withOpacity(0.9), border:Border.all(color:t.accent.withOpacity(0.4), width:2),
                boxShadow:[BoxShadow(color:t.accent.withOpacity(0.2), blurRadius:20, spreadRadius:4)]),
            child:Center(child:Text(o.icon, style:const TextStyle(fontSize:56)))),
        const SizedBox(height:16),
        Text(o.name, style:TextStyle(color:t.textPrimary, fontSize:26, fontWeight:FontWeight.bold, letterSpacing:1.5)),
        const SizedBox(height:8),
        Container(padding:const EdgeInsets.symmetric(horizontal:16, vertical:6),
            decoration:BoxDecoration(color:t.accent.withOpacity(0.1), borderRadius:BorderRadius.circular(20), border:Border.all(color:t.accent.withOpacity(0.4))),
            child:Text(o.type.toUpperCase(), style:TextStyle(color:t.accent, fontSize:11, fontWeight:FontWeight.bold, letterSpacing:2))),
        const SizedBox(height:16),
        Container(width:double.infinity, padding:const EdgeInsets.all(16),
            decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.border.withOpacity(0.4))),
            child:Text(o.description, textAlign:TextAlign.center, style:TextStyle(color:t.textPrimary, fontSize:14, height:1.6))),
        const SizedBox(height:14),
        GridView.count(crossAxisCount:2, shrinkWrap:true, physics:const NeverScrollableScrollPhysics(), crossAxisSpacing:12, mainAxisSpacing:12, childAspectRatio:1.6,
            children:[_IT('📏','Distance',o.distance,t), _IT('👁️','Visibility',o.visibility,t), _IT('📅','Best Months',o.bestMonths,t), _IT('🌐','RA/Dec','${o.raHours.toStringAsFixed(1)}h / ${o.decDeg.toStringAsFixed(1)}°',t)]),
        const SizedBox(height:14),
        Container(width:double.infinity, padding:const EdgeInsets.all(16),
            decoration:BoxDecoration(color:t.accent.withOpacity(0.08), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.accent.withOpacity(0.3))),
            child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
              Text('💡 FUN FACT', style:TextStyle(color:t.accent, fontSize:10, fontWeight:FontWeight.bold, letterSpacing:2)),
              const SizedBox(height:8),
              Text(o.funFact, style:TextStyle(color:t.textPrimary, fontSize:13, height:1.5)),
            ])),
        const SizedBox(height:12),
        Container(width:double.infinity, padding:const EdgeInsets.all(16),
            decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.border.withOpacity(0.3))),
            child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
              Text('🚀 NASA FACT', style:TextStyle(color:t.textSecondary, fontSize:10, fontWeight:FontWeight.bold, letterSpacing:2)),
              const SizedBox(height:8),
              Text(o.nasaFact, style:TextStyle(color:t.textPrimary, fontSize:13, height:1.5)),
            ])),
        const SizedBox(height:24),
        GestureDetector(onTap:()=>Navigator.pop(context),
            child:Container(width:double.infinity, padding:const EdgeInsets.symmetric(vertical:16),
                decoration:BoxDecoration(borderRadius:BorderRadius.circular(14), gradient:LinearGradient(colors:[t.accent, t.accent.withOpacity(0.6)]), boxShadow:[BoxShadow(color:t.accent.withOpacity(0.3), blurRadius:12)]),
                child:Center(child:Text('◀  BACK', style:TextStyle(color:t.lightTheme?Colors.white:t.bg, fontWeight:FontWeight.bold, fontSize:14, letterSpacing:2))))),
        const SizedBox(height:20),
      ]))),
    );
  }
}

class _IT extends StatelessWidget {
  final String ic,lb,vl; final SkyTheme t;
  const _IT(this.ic, this.lb, this.vl, this.t);
  @override
  Widget build(BuildContext context) => Container(padding:const EdgeInsets.all(12),
      decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:t.border.withOpacity(0.3))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start, mainAxisAlignment:MainAxisAlignment.center,
          children:[Text(ic, style:const TextStyle(fontSize:18)), const SizedBox(height:4), Text(lb, style:TextStyle(color:t.textSecondary, fontSize:10)), Text(vl, style:TextStyle(color:t.textPrimary, fontSize:12, fontWeight:FontWeight.bold))]));
}

// ─────────────────────────────────────────────
//  DARK SKY BODY
// ─────────────────────────────────────────────
class DarkSkyBody extends StatefulWidget {
  final SkyTheme theme; final Position? position; final VoidCallback onRequestLocation;
  const DarkSkyBody({super.key, required this.theme, this.position, required this.onRequestLocation});
  @override
  State<DarkSkyBody> createState() => _DarkSkyBodyState();
}

class _DarkSkyBodyState extends State<DarkSkyBody> {
  Future<void> _maps(DarkSkySpot s) async {
    final url=Uri.parse('https://www.google.com/maps/search/?api=1&query=${s.lat},${s.lng}');
    if(await canLaunchUrl(url)) await launchUrl(url, mode:LaunchMode.externalApplication);
  }
  Color _qc(String q){ if(q=='Excellent') return Colors.greenAccent; if(q=='Very Good') return Colors.lightGreenAccent; if(q=='Good') return Colors.yellowAccent; return Colors.orangeAccent; }

  @override
  Widget build(BuildContext context) {
    final t=widget.theme; final pos=widget.position;
    return ThemedBackground(theme:t, child:SingleChildScrollView(padding:const EdgeInsets.all(16), child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
      Container(width:double.infinity, padding:const EdgeInsets.all(18),
          decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(18), border:Border.all(color:t.accent.withOpacity(0.3))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text('YOUR LOCATION', style:TextStyle(color:t.textSecondary, fontSize:10, letterSpacing:2, fontWeight:FontWeight.bold)),
            const SizedBox(height:12),
            if(pos==null)...[
              Row(children:[const Text('📍', style:TextStyle(fontSize:30)), const SizedBox(width:12),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                  Text('Location not found', style:TextStyle(color:t.textPrimary, fontSize:15, fontWeight:FontWeight.bold)),
                  Text('GPS permission needed', style:TextStyle(color:t.textSecondary, fontSize:12))])),
                GestureDetector(onTap:widget.onRequestLocation,
                    child:Container(padding:const EdgeInsets.symmetric(horizontal:14, vertical:8),
                        decoration:BoxDecoration(color:t.accent.withOpacity(0.15), borderRadius:BorderRadius.circular(12), border:Border.all(color:t.accent.withOpacity(0.4))),
                        child:Text('Enable', style:TextStyle(color:t.accent, fontWeight:FontWeight.bold, fontSize:13)))),
              ]),
            ]else...[
              Row(children:[const Text('📍', style:TextStyle(fontSize:32)), const SizedBox(width:12),
                Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                  Text('${pos.latitude.toStringAsFixed(4)}° N', style:TextStyle(color:t.textPrimary, fontSize:16, fontWeight:FontWeight.bold)),
                  Text('${pos.longitude.toStringAsFixed(4)}° E', style:TextStyle(color:t.textPrimary, fontSize:16, fontWeight:FontWeight.bold)),
                  Text('Sky Quality: Moderate', style:TextStyle(color:Colors.orangeAccent, fontSize:13)),
                ]),
              ]),
              const SizedBox(height:12),
              Row(children:[Text('Bad ', style:TextStyle(color:t.textSecondary, fontSize:10)),
                Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(4), child:LinearProgressIndicator(value:0.35, minHeight:8, backgroundColor:t.border.withOpacity(0.3), valueColor:const AlwaysStoppedAnimation(Colors.orangeAccent)))),
                Text(' Perfect', style:TextStyle(color:t.textSecondary, fontSize:10))]),
            ],
          ])),
      const SizedBox(height:20),
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
        Text('NEAREST DARK SKY SPOTS', style:TextStyle(color:t.accent, fontSize:11, fontWeight:FontWeight.bold, letterSpacing:2)),
        if(pos!=null) Text('Sorted by distance', style:TextStyle(color:t.textSecondary, fontSize:10)),
      ]),
      const SizedBox(height:10),
      ...darkSkySpots.map((s)=>Container(margin:const EdgeInsets.only(bottom:12), padding:const EdgeInsets.all(16),
          decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.border.withOpacity(0.3))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
              Expanded(child:Text(s.name, style:TextStyle(color:t.textPrimary, fontSize:14, fontWeight:FontWeight.bold))),
              Container(padding:const EdgeInsets.symmetric(horizontal:10, vertical:4),
                  decoration:BoxDecoration(color:_qc(s.quality).withOpacity(0.15), borderRadius:BorderRadius.circular(12), border:Border.all(color:_qc(s.quality).withOpacity(0.5))),
                  child:Text(s.quality, style:TextStyle(color:_qc(s.quality), fontSize:11, fontWeight:FontWeight.bold))),
            ]),
            const SizedBox(height:6),
            Text(s.description, style:TextStyle(color:t.textSecondary, fontSize:12)),
            const SizedBox(height:10),
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
              Row(children:[Icon(Icons.drive_eta, color:t.textSecondary, size:14), const SizedBox(width:4),
                Text(pos!=null&&s.distanceKm>0?'${s.distanceKm.toStringAsFixed(0)} km away':'Distance unknown', style:TextStyle(color:t.textSecondary, fontSize:12))]),
              GestureDetector(onTap:()=>_maps(s),
                  child:Container(padding:const EdgeInsets.symmetric(horizontal:12, vertical:6),
                      decoration:BoxDecoration(color:t.accent.withOpacity(0.15), borderRadius:BorderRadius.circular(10), border:Border.all(color:t.accent.withOpacity(0.4))),
                      child:Row(children:[Icon(Icons.map_outlined, color:t.accent, size:14), const SizedBox(width:4), Text('Open Maps', style:TextStyle(color:t.accent, fontSize:12, fontWeight:FontWeight.bold))]))),
            ]),
          ]))),
      Container(width:double.infinity, padding:const EdgeInsets.all(16),
          decoration:BoxDecoration(color:t.accent.withOpacity(0.08), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.accent.withOpacity(0.25))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
            Text('🌟 STARGAZING TIPS', style:TextStyle(color:t.accent, fontSize:11, fontWeight:FontWeight.bold, letterSpacing:2)),
            const SizedBox(height:10),
            ...['Let your eyes adjust for 20 min in darkness','Check weather forecast before heading out','Use red torch — it preserves night vision','New Moon nights have the darkest skies'].map((tip)=>
                Padding(padding:const EdgeInsets.only(bottom:6), child:Row(children:[Text('→  ', style:TextStyle(color:t.accent, fontSize:12)), Expanded(child:Text(tip, style:TextStyle(color:t.textPrimary, fontSize:12)))]))),
          ])),
      const SizedBox(height:20),
    ])));
  }
}

// ─────────────────────────────────────────────
//  OBSERVATION LOG BODY
// ─────────────────────────────────────────────
class ObservationLogBody extends StatefulWidget {
  final SkyTheme theme;
  const ObservationLogBody({super.key, required this.theme});
  @override
  State<ObservationLogBody> createState() => _LogBodyState();
}

class _LogBodyState extends State<ObservationLogBody> {
  List<Map<String,String>> _entries=[];
  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final prefs=await SharedPreferences.getInstance();
    final logs=prefs.getStringList('logs')??[];
    setState((){
      _entries=logs.reversed.map((log){
        final p=log.split('|');
        return p.length>=5 ? {'name':p[0],'icon':p[1],'type':p[2],'date':p[3],'note':p[4]} : null;
      }).whereType<Map<String,String>>().toList();
    });
  }

  Future<void> _delete(int i) async {
    final prefs=await SharedPreferences.getInstance();
    final logs=prefs.getStringList('logs')??[];
    final a=logs.length-1-i;
    if(a>=0){ logs.removeAt(a); await prefs.setStringList('logs',logs); _load(); }
  }

  Future<void> _editNote(int i) async {
    final t=widget.theme; final entry=_entries[i];
    final ctrl=TextEditingController(text:entry['note']);
    await showDialog(context:context, builder:(_)=>AlertDialog(
      backgroundColor:t.card,
      title:Row(children:[Text(entry['icon']??'⭐', style:const TextStyle(fontSize:24)), const SizedBox(width:10), Text(entry['name']??'', style:TextStyle(color:t.textPrimary, fontWeight:FontWeight.bold))]),
      content:Column(mainAxisSize:MainAxisSize.min, children:[
        Text('Edit note:', style:TextStyle(color:t.textSecondary, fontSize:12)), const SizedBox(height:10),
        TextField(controller:ctrl, style:TextStyle(color:t.textPrimary), maxLines:4,
            decoration:InputDecoration(filled:true, fillColor:t.bg, border:OutlineInputBorder(borderRadius:BorderRadius.circular(12), borderSide:BorderSide(color:t.border.withOpacity(0.4))))),
      ]),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(context), child:Text('Cancel', style:TextStyle(color:t.textSecondary))),
        TextButton(onPressed:() async {
          Navigator.pop(context);
          final prefs=await SharedPreferences.getInstance();
          final logs=prefs.getStringList('logs')??[];
          final idx=logs.length-1-i;
          if(idx>=0){
            final parts=logs[idx].split('|');
            if(parts.length>=5){ parts[4]=ctrl.text.isEmpty?'Observed via SkyPointer':ctrl.text; logs[idx]=parts.join('|'); await prefs.setStringList('logs',logs); _load(); }
          }
        }, child:Text('Save', style:TextStyle(color:t.accent, fontWeight:FontWeight.bold))),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t=widget.theme;

    if(_entries.isEmpty) {
      return ThemedBackground(theme:t, child:Center(child:Column(mainAxisAlignment:MainAxisAlignment.center, children:[
        const Text('📝', style:TextStyle(fontSize:60)), const SizedBox(height:16),
        Text('No observations yet', style:TextStyle(color:t.textPrimary, fontSize:18, fontWeight:FontWeight.bold)),
        const SizedBox(height:8),
        Text('Go to Navigate and tap LOG IT', style:TextStyle(color:t.textSecondary, fontSize:13), textAlign:TextAlign.center),
      ])));
    }

    // ── FIX: Single clean return, no duplicate code ──
    return ThemedBackground(
      theme: t,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _entries.length,
        itemBuilder: (_, i) {
          final e = _entries[i];
          return Dismissible(
            key: Key('$i${e['name']}${e['date']}'),
            direction: DismissDirection.endToStart,
            onDismissed: (_) => _delete(i),
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: BoxDecoration(color:Colors.redAccent.withOpacity(0.15), borderRadius:BorderRadius.circular(14)),
              child: const Icon(Icons.delete, color:Colors.redAccent),
            ),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.border.withOpacity(0.3))),
              child: Column(children:[
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children:[
                    Container(width:46, height:46,
                        decoration:BoxDecoration(shape:BoxShape.circle, color:t.accent.withOpacity(0.1), border:Border.all(color:t.accent.withOpacity(0.3))),
                        child:Center(child:Text(e['icon']??'⭐', style:const TextStyle(fontSize:22)))),
                    const SizedBox(width:12),
                    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                      Text(e['name']??'', style:TextStyle(color:t.textPrimary, fontSize:14, fontWeight:FontWeight.bold)),
                      Text(e['date']??'', style:TextStyle(color:t.accent, fontSize:11)),
                      Container(margin:const EdgeInsets.only(top:2), padding:const EdgeInsets.symmetric(horizontal:8, vertical:2),
                          decoration:BoxDecoration(color:t.accent.withOpacity(0.1), borderRadius:BorderRadius.circular(8)),
                          child:Text(e['type']??'', style:TextStyle(color:t.accent, fontSize:9))),
                    ])),
                    IconButton(icon:Icon(Icons.edit_note, color:t.textSecondary, size:22), onPressed:()=>_editNote(i)),
                  ]),
                ),
                if((e['note']??'').isNotEmpty)
                  Container(width:double.infinity, margin:const EdgeInsets.fromLTRB(14,0,14,14), padding:const EdgeInsets.all(12),
                      decoration:BoxDecoration(color:t.accent.withOpacity(0.06), borderRadius:BorderRadius.circular(10), border:Border.all(color:t.accent.withOpacity(0.2))),
                      child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                        Text('📓 MY NOTE', style:TextStyle(color:t.accent, fontSize:9, fontWeight:FontWeight.bold, letterSpacing:1.5)),
                        const SizedBox(height:6),
                        Text(e['note']??'', style:TextStyle(color:t.textPrimary, fontSize:12, height:1.5)),
                      ])),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  FAVOURITES BODY
// ─────────────────────────────────────────────
class FavouritesBody extends StatefulWidget {
  final SkyTheme theme; final VoidCallback onRefresh;
  const FavouritesBody({super.key, required this.theme, required this.onRefresh});
  @override
  State<FavouritesBody> createState() => _FavBodyState();
}

class _FavBodyState extends State<FavouritesBody> {
  @override
  void initState() { super.initState(); themeNotifier.addListener(()=>setState((){})); }

  Future<void> _remove(CelestialObject o) async {
    final prefs=await SharedPreferences.getInstance();
    final favs=prefs.getStringList('favourites')??[];
    favs.remove(o.name);
    await prefs.setStringList('favourites',favs);
    setState(()=>o.isFavourite=false);
    widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final t=widget.theme;
    final favs=celestialObjects.where((o)=>o.isFavourite).toList();

    if(favs.isEmpty) return ThemedBackground(theme:t, child:Center(child:Column(mainAxisAlignment:MainAxisAlignment.center, children:[
      const Text('⭐', style:TextStyle(fontSize:60)), const SizedBox(height:16),
      Text('No favourites yet', style:TextStyle(color:t.textPrimary, fontSize:18, fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      Text('Tap ⭐ on any object\nto save it here', style:TextStyle(color:t.textSecondary, fontSize:13, height:1.5), textAlign:TextAlign.center),
    ])));

    return ThemedBackground(theme:t, child:ListView.builder(padding:const EdgeInsets.all(16), itemCount:favs.length,
        itemBuilder:(_,i){
          final o=favs[i];
          return Container(margin:const EdgeInsets.only(bottom:10), padding:const EdgeInsets.all(14),
              decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(14), border:Border.all(color:Colors.amber.withOpacity(0.3))),
              child:Row(children:[
                Container(width:48, height:48, decoration:BoxDecoration(shape:BoxShape.circle, color:Colors.amber.withOpacity(0.1), border:Border.all(color:Colors.amber.withOpacity(0.3))),
                    child:Center(child:Text(o.icon, style:const TextStyle(fontSize:22)))),
                const SizedBox(width:12),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                  Text(o.name, style:TextStyle(color:t.textPrimary, fontSize:14, fontWeight:FontWeight.bold)),
                  Text(o.type, style:TextStyle(color:t.accent, fontSize:11)),
                  Text('Visibility: ${o.visibility}', style:TextStyle(color:t.textSecondary, fontSize:11)),
                ])),
                IconButton(icon:const Icon(Icons.star, color:Colors.amber, size:22), onPressed:()=>_remove(o)),
                IconButton(icon:Icon(Icons.chevron_right, color:t.textSecondary), onPressed:()=>Navigator.push(context, MaterialPageRoute(builder:(_)=>ObjectInfoScreen(object:o)))),
              ]));
        }));
  }
}

// ─────────────────────────────────────────────
//  THEME SCREEN
// ─────────────────────────────────────────────
class ThemeScreen extends StatefulWidget {
  const ThemeScreen({super.key});
  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  @override
  void initState() { super.initState(); themeNotifier.addListener(()=>setState((){})); }

  @override
  Widget build(BuildContext context) {
    final t=themeNotifier.current;
    return Scaffold(
      backgroundColor:t.bgGradEnd,
      appBar:AppBar(backgroundColor:t.card.withOpacity(0.95), elevation:0,
          leading:IconButton(icon:Icon(Icons.arrow_back_ios, color:t.textPrimary), onPressed:()=>Navigator.pop(context)),
          title:Text('Choose Theme', style:TextStyle(color:t.textPrimary, fontSize:18, fontWeight:FontWeight.bold))),
      body:ThemedBackground(theme:t, child:Column(children:[
        Container(margin:const EdgeInsets.all(16), padding:const EdgeInsets.all(16),
            decoration:BoxDecoration(color:t.card.withOpacity(0.9), borderRadius:BorderRadius.circular(16), border:Border.all(color:t.accent.withOpacity(0.5))),
            child:Row(children:[Text(t.emoji, style:const TextStyle(fontSize:30)), const SizedBox(width:14),
              Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                Text('CURRENT THEME', style:TextStyle(color:t.textSecondary, fontSize:10, letterSpacing:2)),
                Text(t.name, style:TextStyle(color:t.accent, fontSize:20, fontWeight:FontWeight.bold)),
                Text(t.desc, style:TextStyle(color:t.textSecondary, fontSize:12)),
              ])])),

        Expanded(child:GridView.builder(padding:const EdgeInsets.symmetric(horizontal:16),
            gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2, crossAxisSpacing:12, mainAxisSpacing:12, childAspectRatio:1.5),
            itemCount:allThemes.length,
            itemBuilder:(_,i){
              final th=allThemes[i]; final sel=themeNotifier.current.key==th.key;
              return GestureDetector(
                onTap:(){ themeNotifier.setTheme(th); setState((){}); },
                child:AnimatedContainer(duration:const Duration(milliseconds:250), padding:const EdgeInsets.all(14),
                    decoration:BoxDecoration(
                        gradient:LinearGradient(begin:Alignment.topLeft, end:Alignment.bottomRight, colors:[th.bgGradStart, th.card]),
                        borderRadius:BorderRadius.circular(16),
                        border:Border.all(color:sel?th.accent:th.border.withOpacity(0.4), width:sel?2:1),
                        boxShadow:sel?[BoxShadow(color:th.accent.withOpacity(0.3), blurRadius:12)]:null),
                    child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
                        Container(width:12, height:12, decoration:BoxDecoration(shape:BoxShape.circle, color:th.accent)),
                        if(sel) Icon(Icons.check_circle, color:th.accent, size:16),
                      ]),
                      const Spacer(),
                      Text(th.emoji, style:const TextStyle(fontSize:20)),
                      const SizedBox(height:3),
                      Text(th.name, style:TextStyle(color:th.textPrimary, fontSize:13, fontWeight:FontWeight.bold)),
                      Text(th.desc, style:TextStyle(color:th.textSecondary, fontSize:10)),
                    ])),
              );
            })),

        Padding(padding:const EdgeInsets.all(16),
            child:GestureDetector(onTap:()=>Navigator.pop(context),
                child:Container(width:double.infinity, padding:const EdgeInsets.symmetric(vertical:16),
                    decoration:BoxDecoration(borderRadius:BorderRadius.circular(14), gradient:LinearGradient(colors:[t.accent, t.accent.withOpacity(0.7)]), boxShadow:[BoxShadow(color:t.accent.withOpacity(0.35), blurRadius:14)]),
                    child:Center(child:Text('APPLY  ${t.emoji}  ${t.name.toUpperCase()}', style:TextStyle(color:t.lightTheme?Colors.white:t.bg, fontWeight:FontWeight.bold, fontSize:14, letterSpacing:1.5)))))),
      ])),
    );
  }
}