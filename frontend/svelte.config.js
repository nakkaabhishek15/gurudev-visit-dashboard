import adapter from '@sveltejs/adapter-static';

// Static output uploaded to S3 and served by CloudFront. `fallback` makes every
// unknown path render index.html, which is what the CloudFront SPA-rewrite
// function in terraform/envs/prod/app_frontend.tf assumes.
const config = {
  kit: {
    adapter: adapter({
      fallback: 'index.html'
    })
  }
};

export default config;
