/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  images: { unoptimized: true },
  // The neuron-anatomy package ships TypeScript sources only (no
  // pre-built JS), so Next.js must transpile it like first-party code.
  transpilePackages: ['@aws-neuron-samples/neuron-anatomy'],
};

export default nextConfig;
