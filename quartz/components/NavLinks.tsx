import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { i18n } from "../i18n"
import { classNames } from "../util/lang"
import { resolveRelative } from "../util/path"

const NavLinks: QuartzComponent = ({ displayClass, fileData }: QuartzComponentProps) => {
  const tagsPath = resolveRelative(fileData.slug!, "tags")
  return (
    <div className={classNames(displayClass, "nav-links")}>
      <ul style={{ listStyle: "none", padding: 0, margin: "1rem 0" }}>
        <li style={{ margin: "0.5rem 0" }}>
          <a href={tagsPath} style={{ textDecoration: "none", display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <span>🏷️</span>
            <span>所有标签</span>
          </a>
        </li>
      </ul>
    </div>
  )
}

export default (() => NavLinks) satisfies QuartzComponentConstructor
