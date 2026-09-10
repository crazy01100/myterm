# MyTerm Update Site

[繁體中文](README.md) | **English**

This directory contains the static source for `https://mtus.lieniapp.work`.

- Cloudflare Pages uses Direct Upload rather than connecting directly to the private GitHub repository.
- The repository's `appcast.xml` preserves a signed historical feed and does not represent the latest online version. The deployed feed comes from the signed assets of the specified GitHub Release. Do not manually edit or re-sign a published feed.
- The primary development Mac creates the release ZIP, appcast, and release notes. GitHub Actions verifies and deploys them.
- If automatic deployment fails, the repository owner can redeploy an existing published version with the workflow's `release_tag` input. The workflow still uses only that release's signed assets.
- After deployment, an external GitHub runner downloads the homepage, appcast, release notes, and ZIP again to check the version, SHA-256, contents, and security headers. This prevents corporate-network DNS restrictions from masking public-site problems.
- Do not add Sparkle private keys, Cloudflare tokens, OAuth secrets, local Firebase configuration, or user data to this directory.
