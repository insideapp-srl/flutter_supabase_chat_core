# Documentation site

Source of https://flutter-supabase-chat-core.insideapp.it, built with
[Docusaurus](https://docusaurus.io/). Pages live in `docs/`, the sidebar order
in `sidebars.ts`.

### Installation

```
$ npm ci
```

### Local development

```
$ npm start
```

Starts a local development server with live reload.

### Build

```
$ npm run build
```

Generates the static site into `build/`.

### Deployment

The site is deployed to GitHub Pages by the `Deploy GitHub pages` workflow
(`.github/workflows/deploy-pages.yaml`) on every push to `main`; no manual
deploy is needed.
