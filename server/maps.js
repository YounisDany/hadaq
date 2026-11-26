// Place search + walking routes for Hadaq.
// Uses Google Maps Platform when GOOGLE_MAPS_KEY is set (best data in Saudi Arabia),
// otherwise free OpenStreetMap services (Nominatim search + OSRM foot routing).

const UA = 'HadaqAssistant/1.0 (+https://hadaq.waal.dev)';

// ---------------------------------------------------------------- geo helpers
const R = 6371000;
const rad = (d) => (d * Math.PI) / 180;
export function distance(a, b) {
  const dLat = rad(b[0] - a[0]);
  const dLon = rad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
export function bearing(a, b) {
  const y = Math.sin(rad(b[1] - a[1])) * Math.cos(rad(b[0]));
  const x = Math.cos(rad(a[0])) * Math.sin(rad(b[0])) - Math.sin(rad(a[0])) * Math.cos(rad(b[0])) * Math.cos(rad(b[1] - a[1]));
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

// ---------------------------------------------------------------- caches / throttle
const cache = new Map();
const cached = async (key, ttlMs, fn) => {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < ttlMs) return hit.v;
  const v = await fn();
  cache.set(key, { t: Date.now(), v });
  if (cache.size > 500) cache.delete(cache.keys().next().value);
  return v;
};
// Nominatim's usage policy: max 1 request/second from this server.
let lastNominatim = 0;
const nominatimSlot = async () => {
  const wait = lastNominatim + 1100 - Date.now();
  lastNominatim = Math.max(Date.now(), lastNominatim + 1100);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
};

// ---------------------------------------------------------------- query cleanup
// "محل شاورما" -> also try "شاورما"; "صيدليه" spelling variants are left to the search engine.
const GENERIC = ['محل', 'مطعم', 'مكان', 'دكان', 'بقالة', 'سوق'];
function queryVariants(q) {
  const clean = q.replace(/[؟?!.,،]/g, ' ').replace(/\s+/g, ' ').trim();
  const out = [clean];
  const words = clean.split(' ');
  if (words.length > 1 && GENERIC.includes(words[0])) out.push(words.slice(1).join(' '));
  return [...new Set(out)];
}

// ---------------------------------------------------------------- search
/** Returns up to 5 places sorted by distance: { name, lat, lon, distance, bearing, address, open_now?, rating? } */
export async function searchPlaces({ query, lat, lon, googleKey }) {
  const here = [lat, lon];
  let places = [];
  let source = 'osm';
  if (googleKey) {
    places = await googleSearch(query, lat, lon, googleKey).catch(() => []);
    source = 'google';
  }
  if (!places.length) {
    source = 'osm';
    for (const q of queryVariants(query)) {
      for (const d of [0.03, 0.08]) { // ~3 km, then ~8 km box
        places = await nominatimSearch(q, lat, lon, d);
        if (places.length) break;
      }
      if (places.length) break;
    }
  }
  places = places
    .map((p) => ({ ...p, distance: Math.round(distance(here, [p.lat, p.lon])), bearing: Math.round(bearing(here, [p.lat, p.lon])) }))
    .sort((a, b) => a.distance - b.distance);
  // Drop duplicates (same name within 30 m).
  const unique = [];
  for (const p of places) {
    if (!unique.some((u) => u.name === p.name && distance([u.lat, u.lon], [p.lat, p.lon]) < 30)) unique.push(p);
  }
  return { source, places: unique.slice(0, 5) };
}

async function nominatimSearch(q, lat, lon, d) {
  const key = `n:${q}:${lat.toFixed(3)}:${lon.toFixed(3)}:${d}`;
  return cached(key, 10 * 60_000, async () => {
    await nominatimSlot();
    const u = new URL('https://nominatim.openstreetmap.org/search');
    u.search = new URLSearchParams({
      format: 'jsonv2', limit: '15', bounded: '1', addressdetails: '1', 'accept-language': 'ar',
      viewbox: `${lon - d},${lat + d},${lon + d},${lat - d}`, q,
    });
    const r = await fetch(u, { headers: { 'User-Agent': UA } });
    if (!r.ok) return [];
    const j = await r.json();
    return j.map((x) => ({
      name: x.name || x.display_name.split(',')[0],
      lat: Number(x.lat),
      lon: Number(x.lon),
      address: [x.address?.road, x.address?.suburb || x.address?.neighbourhood].filter(Boolean).join('، '),
    }));
  });
}

async function googleSearch(q, lat, lon, key) {
  const r = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': key,
      'X-Goog-FieldMask': 'places.displayName,places.location,places.shortFormattedAddress,places.currentOpeningHours.openNow,places.rating',
    },
    body: JSON.stringify({
      textQuery: q,
      languageCode: 'ar',
      rankPreference: 'DISTANCE',
      locationBias: { circle: { center: { latitude: lat, longitude: lon }, radius: 5000 } },
      pageSize: 10,
    }),
  });
  if (!r.ok) throw new Error(`google ${r.status}`);
  const j = await r.json();
  return (j.places || []).map((p) => ({
    name: p.displayName?.text || q,
    lat: p.location.latitude,
    lon: p.location.longitude,
    address: p.shortFormattedAddress || '',
    open_now: p.currentOpeningHours?.openNow,
    rating: p.rating,
  }));
}

// ---------------------------------------------------------------- walking route
/** Returns { distance, duration, source, steps:[{lat,lon,distance,text,type,modifier,name}], geometry:[[lat,lon],...] } */
export async function walkingRoute({ from, to, googleKey }) {
  if (googleKey) {
    try { return await googleRoute(from, to, googleKey); } catch { /* fall back to OSM */ }
  }
  return osrmRoute(from, to);
}

async function osrmRoute(from, to) {
  const u = `https://routing.openstreetmap.de/routed-foot/route/v1/driving/${from[1]},${from[0]};${to[1]},${to[0]}?steps=true&overview=full&geometries=geojson`;
  const r = await fetch(u, { headers: { 'User-Agent': UA } });
  if (!r.ok) throw new Error(`osrm ${r.status}`);
  const j = await r.json();
  const route = j.routes?.[0];
  if (!route) throw new Error('no_route');
  const steps = route.legs[0].steps.map((s) => ({
    lat: s.maneuver.location[1],
    lon: s.maneuver.location[0],
    distance: Math.round(s.distance),
    type: s.maneuver.type,
    modifier: s.maneuver.modifier || '',
    name: s.name || '',
    exit: s.maneuver.exit,
  }));
  for (const s of steps) s.text = arabicInstruction(s);
  return {
    source: 'osm',
    distance: Math.round(route.distance),
    duration: Math.round(route.duration),
    steps,
    geometry: route.geometry.coordinates.map(([x, y]) => [y, x]),
  };
}

async function googleRoute(from, to, key) {
  const r = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': key,
      'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.distanceMeters,routes.legs.steps.startLocation,routes.legs.steps.navigationInstruction',
    },
    body: JSON.stringify({
      origin: { location: { latLng: { latitude: from[0], longitude: from[1] } } },
      destination: { location: { latLng: { latitude: to[0], longitude: to[1] } } },
      travelMode: 'WALK',
      languageCode: 'ar',
    }),
  });
  if (!r.ok) throw new Error(`google ${r.status}`);
  const j = await r.json();
  const route = j.routes?.[0];
  if (!route) throw new Error('no_route');
  const steps = route.legs[0].steps.map((s) => ({
    lat: s.startLocation.latLng.latitude,
    lon: s.startLocation.latLng.longitude,
    distance: s.distanceMeters || 0,
    type: (s.navigationInstruction?.maneuver || '').toLowerCase(),
    modifier: '',
    name: '',
    text: (s.navigationInstruction?.instructions || '').replace(/\n/g, '، '),
  }));
  steps.push({ lat: to[0], lon: to[1], distance: 0, type: 'arrive', modifier: '', name: '', text: 'وصلت إلى وجهتك' });
  return {
    source: 'google',
    distance: route.distanceMeters,
    duration: Number(String(route.duration).replace('s', '')) || 0,
    steps,
    geometry: decodePolyline(route.polyline.encodedPolyline),
  };
}

function decodePolyline(str) {
  let index = 0, lat = 0, lng = 0;
  const out = [];
  while (index < str.length) {
    for (const which of [0, 1]) {
      let b, shift = 0, result = 0;
      do { b = str.charCodeAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      const d = result & 1 ? ~(result >> 1) : result >> 1;
      if (which === 0) lat += d; else lng += d;
    }
    out.push([lat / 1e5, lng / 1e5]);
  }
  return out;
}

// ---------------------------------------------------------------- Arabic instructions (OSRM)
const TURN = {
  left: 'انعطف يسارًا',
  right: 'انعطف يمينًا',
  'slight left': 'انحرف قليلًا إلى اليسار',
  'slight right': 'انحرف قليلًا إلى اليمين',
  'sharp left': 'انعطف بحدة إلى اليسار',
  'sharp right': 'انعطف بحدة إلى اليمين',
  straight: 'تابع للأمام',
  uturn: 'استدر للخلف',
};
const onto = (name) => (name ? (/^(شارع|طريق|ممر|دوار|ميدان)/.test(name) ? ` إلى ${name}` : ` إلى شارع ${name}`) : '');
const along = (name) => (name ? (/^(شارع|طريق|ممر)/.test(name) ? ` على ${name}` : ` على شارع ${name}`) : '');

export function arabicInstruction(s) {
  switch (s.type) {
    case 'depart': return `ابدأ السير${along(s.name)}`;
    case 'arrive': return 'وصلت إلى وجهتك';
    case 'roundabout':
    case 'rotary':
      return `ادخل الدوار${s.exit ? ` واخرج من المخرج ${['الأول', 'الثاني', 'الثالث', 'الرابع', 'الخامس'][s.exit - 1] || s.exit}` : ''}${onto(s.name)}`;
    case 'continue':
    case 'new name':
      return s.modifier && s.modifier !== 'straight' ? `${TURN[s.modifier] || 'تابع'}${onto(s.name)}` : `تابع للأمام${along(s.name)}`;
    default:
      return `${TURN[s.modifier] || 'تابع للأمام'}${onto(s.name)}`;
  }
}
