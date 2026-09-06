import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { classNames } from "../util/lang"
import { resolveRelative, SimpleSlug } from "../util/path"

const NavLinks: QuartzComponent = ({ displayClass, fileData }: QuartzComponentProps) => {
  const homePath = resolveRelative(fileData.slug!, "index" as SimpleSlug)
  const tagsPath = resolveRelative(fileData.slug!, "tags" as SimpleSlug)
  const seriesPath = resolveRelative(fileData.slug!, "series" as SimpleSlug)
  const codePath = resolveRelative(fileData.slug!, "static/code/index.html" as SimpleSlug)

  return (
    <div className={classNames(displayClass, "nav-links")}>
      <ul style={{ listStyle: "none", padding: 0, margin: "1rem 0" }}>
        <li style={{ margin: "0.8rem 0" }}>
          <a href={homePath} className="nav-link-item">
            <span className="icon">🏠</span>
            <span className="text">首页</span>
          </a>
        </li>
        <li style={{ margin: "0.8rem 0" }}>
          <a href={seriesPath} className="nav-link-item">
            <span className="icon">📚</span>
            <span className="text">系列总览</span>
          </a>
        </li>
        <li style={{ margin: "0.8rem 0" }}>
          <a href={codePath} className="nav-link-item">
            <span className="icon">💻</span>
            <span className="text">示例代码</span>
          </a>
        </li>
        <li style={{ margin: "0.8rem 0" }}>
          <a href={tagsPath} className="nav-link-item">
            <span className="icon">🏷️</span>
            <span className="text">所有标签</span>
          </a>
        </li>
      </ul>
    </div>
  )
}

NavLinks.css = `
.nav-links {
  margin-bottom: 1.5rem;
}

.nav-link-item {
  text-decoration: none;
  display: flex;
  align-items: center;
  gap: 0.8rem;
  color: var(--darkgray);
  font-size: 0.95rem;
  padding: 0.4rem 0.6rem;
  border-radius: 6px;
  transition: all 0.2s ease;
}

.nav-link-item:hover {
  background-color: var(--lightgray);
  color: var(--secondary);
  transform: translateX(5px);
}

.nav-link-item .icon {
  font-size: 1.1rem;
}

.nav-link-item .text {
  font-weight: 500;
}
`

export default (() => NavLinks) satisfies QuartzComponentConstructor
