# Cheeto documentation

The source for [pealz1.github.io/cheeto](https://pealz1.github.io/cheeto), built with [Nextra](https://nextra.site).

## Local development

Requires Node.js 20 or later.

```sh
npm ci
npm run dev
```

Then open http://localhost:3000.

## Building

```sh
npm run build
```

The static site is written to `out/`. Set `NEXT_PUBLIC_BASE_PATH` when the site is served from a sub-path, for example `NEXT_PUBLIC_BASE_PATH=/cheeto` for a GitHub Pages project site. The deploy workflow sets it automatically.

## Layout

| Path | Contents |
| --- | --- |
| `pages/` | Documentation pages, one `.mdx` file per page, ordered by `_meta.json` |
| `components/Landing/` | The home page |
| `styles/globals.css` | Theme overrides for the docs layout |
| `public/syntax/` | The `.cheeto` TextMate grammar and code theme |
