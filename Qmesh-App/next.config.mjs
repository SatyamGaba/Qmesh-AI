import withSerwistInit from "@serwist/next";

const withSerwist = withSerwistInit({
  swSrc: "src/app/sw.ts",
  swDest: "public/sw.js",
  // Disable the SW in dev so it doesn't cache Next's HMR assets.
  disable: process.env.NODE_ENV === "development",
});

/** @type {import("next").NextConfig} */
const nextConfig = {};

export default withSerwist(nextConfig);
