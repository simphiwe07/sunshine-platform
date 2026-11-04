// Demand-growth drill: ramps CPU-heavy traffic so the HPA adds pods, pods go
// Pending when the 2 Spot nodes are full, and the Cluster Autoscaler adds nodes.
//
//   k6 run loadtest/scale-out.js                         # full drill, ~17 min
//   k6 run -e PEAK_RPS=20 -e HOLD=3m loadtest/scale-out.js   # gentler / shorter
//
// The app sits behind Cognito sign-in (phase 6). Sign in once in a browser, copy
// the request's Cookie header (DevTools > Network > any request > Cookie) and:
//   k6 run -e COOKIE='AWSELBAuthSessionCookie-0=...; AWSELBAuthSessionCookie-1=...' loadtest/scale-out.js
//
// Each request burns ~200 ms of CPU in a pod, so 40 req/s ≈ 8 CPU cores of demand -
// far more than 2 t3.medium nodes (≈ 3.8 allocatable cores) can serve.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'https://dev.simptechit.click';
const BURN_MS = __ENV.BURN_MS || '200';
const PEAK = parseInt(__ENV.PEAK_RPS || '40', 10);
const HOLD = __ENV.HOLD || '8m';
const PARAMS = {
  timeout: '60s',
  tags: { name: '/burn' },
  // Never follow the redirect to the sign-in page: a 200 from Cognito's login
  // form would look like success. Without a valid cookie every request fails.
  redirects: 0,
  headers: __ENV.COOKIE ? { Cookie: __ENV.COOKIE } : {},
};

export function setup() {
  const res = http.get(`${BASE}/burn?ms=1`, PARAMS);
  if (res.status !== 200) {
    throw new Error(`/burn returned ${res.status} - sign in and pass -e COOKIE=... (see top of file)`);
  }
}

export const options = {
  scenarios: {
    demand: {
      executor: 'ramping-arrival-rate', // fixed request RATE, like real users - not a fixed number of loops
      startRate: 2,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 300, // requests slow down while capacity is short; more VUs keep the rate up
      stages: [
        { duration: '3m', target: Math.round(PEAK / 4) }, // warm-up: HPA starts adding pods
        { duration: '3m', target: PEAK },                  // surge: pods go Pending -> new nodes
        { duration: HOLD, target: PEAK },                  // sustained: cluster catches up, latency recovers
        { duration: '3m', target: 0 },                     // demand drops: HPA then CA scale back in
      ],
    },
  },
  thresholds: {
    // Not pass/fail for the drill - just shows how much users felt the scale-out.
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<5000'],
  },
};

export default function () {
  const res = http.get(`${BASE}/burn?ms=${BURN_MS}`, PARAMS);
  check(res, { 'status 200': (r) => r.status === 200 });
}
