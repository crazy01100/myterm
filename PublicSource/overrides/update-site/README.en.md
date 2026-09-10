# Self-Hosted Update Site Template

[繁體中文](README.md) | **English**

This directory is a static template for independent distributors, not a hosted service offered by this source project. No prebuilt MyTerm, existing signed appcast, or automatic deployment workflow ships with it.

- Local source builds need no update site; follow the [README](../README.en.md#building-from-source) to build, install, and manually update `MyTerm.app`.
- For in-app updates, establish your own HTTPS host, Sparkle private key, and app verification public key, set `MYTERM_UPDATE_BASE_URL`, and create signed assets using the [development guide](../DEVELOPMENT.en.md).
- `prepare-pages-deployment.sh` places your appcast, ZIP, release notes, and checksums into the deployment output. It does not treat an empty source template as a valid update.
- This repository contains no built appcast. Generate the feed from your release assets and never edit a signed feed manually. Adapt the HTML copy and installation instructions to your own distribution before deployment.
- Host the output on your Cloudflare Pages project or a compatible HTTPS service. Configure your own project, account, and deployment credentials.
- After deploying, run `verify-public-update-site.sh` with your own URL and assets, then validate the update from your app through Sparkle.
- Do not include private keys, tokens, OAuth secrets, real Firebase settings, host inventories, or other user data.
