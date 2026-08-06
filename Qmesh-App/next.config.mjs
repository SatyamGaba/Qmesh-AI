import withSerwistInit from "@serwist/next";

const withSerwist = withSerwistInit({
  swSrc: "src/app/sw.ts",
  swDest: "public/sw.js",
  // Disable the SW in dev so it doesn't cache Next's HMR assets.
  disable: process.env.NODE_ENV === "development",
});

/** @type {import("next").NextConfig} */
const nextConfig = {
  reactStrictMode: false,
  // QMESH_EXPORT=1 emits a static `out/` bundle for the Android shell to serve
  // from assets. Left off, `npm run dev` / `next start` behave exactly as before.
  ...(process.env.QMESH_EXPORT ? { output: "export" } : {}),
};

export default withSerwist(nextConfig);
