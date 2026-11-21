import type { NextConfig } from "next";

const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
];

/**
 * Serve the console under a path (RV_CONSOLE_BASE_PATH=/console) so a site
 * such as rykanv.com can proxy /console/* to it. A build-time setting: Next
 * bakes it into routes and assets.
 */
const basePath = (process.env.RV_CONSOLE_BASE_PATH ?? "").trim().replace(/\/+$/, "");
if (basePath && !/^(\/[a-z0-9._-]+)+$/i.test(basePath)) {
  throw new Error(`RV_CONSOLE_BASE_PATH must look like /console, got ${JSON.stringify(basePath)}`);
}

const nextConfig: NextConfig = {
  output: "standalone",
  ...(basePath && { basePath }),
  env: { NEXT_PUBLIC_RV_BASE_PATH: basePath },
  poweredByHeader: false,
  devIndicators: false,
  serverExternalPackages: ["node:sqlite"],
  // The SQLite data dir and its session secret are runtime state: never ship them.
  outputFileTracingExcludes: { "*": ["data/**", ".env*", "tests/**", "scripts/**", "*.md"] },
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
