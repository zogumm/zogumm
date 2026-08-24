# CSS Navbar Part 09 — glass navbar with sliding submenu

Saved from an Instagram carousel by **@frontendjoe** ("CSS Navbars Part 09", Aug 3).
Transcribed from the screenshots — no JavaScript, hover-driven with `:has()`.

Open `index.html` in a browser to try it.

## Files

| File | What it is |
| --- | --- |
| `index.html` | Markup from the post. See the note below about `submenu-2` / `submenu-3`. |
| `styles.css` | Verbatim from the post (slides 4–6). |
| `logo.svg` | Placeholder hexagon logo — not from the post. |

## How it works

- **Glass panel** — `nav::before` sits at `z-index: -1` with `backdrop-filter: blur(16px) saturate(1.2)`.
  The tint and inner borders live in the `--bg` / `--bs` custom properties on `nav`; because custom
  properties inherit, `.submenu` reuses the exact same glass recipe.
- **One shared dropdown** — there is a single `.submenu` panel. Hovering any top-level `li`
  reveals it (`.menu-inner:has(> ul > li:hover) > .submenu`), and the matching
  `.submenu-N` child is the only one switched to `display: grid`.
- **The slide** — the top-level `ul` is a 3-column grid, so the panel's `left` is nudged by
  `100% / 3` per column: `calc(-24px + 100% / 3)` for item 2, `* 2` for item 3. Since `left`
  is inside the `transition: 0.3s`, the panel glides between items instead of jumping.
- **Hover bridge** — `.submenu > div::before` is a 10px invisible strip (`inset: -10px 0 auto`)
  filling the gap left by `top: calc(100% + 10px)`, so the pointer can travel from the nav
  down into the panel without it closing.
- **Staying open** — `.submenu:hover` and `.submenu:has(> .submenu-N:hover)` repeat the open
  state and the offset, so the panel holds its position while the pointer is inside it.

## Notes

- `index.html` in the post showed only `submenu-1` plus a `<!-- more submenus -->` comment.
  `submenu-2` and `submenu-3` are filled in here so the CSS has something to target;
  the Socials items match slide 1 of the carousel.
- `index.html` also carries a small demo-only `<style>` block: a page backdrop (the glass
  effect is invisible against a flat background) and a `* { margin: 0; padding: 0 }` reset.
  The carousel never showed a reset, but the original clearly had one — without it the UA
  margin/padding on `<ul>` knocks the menu items off-centre. `styles.css` itself is untouched.
- The `settings` icon expects the Material Symbols font; without it you'll just see the word.
- `:has()`, `color-mix()` and `backdrop-filter` are all required — modern browsers only.
