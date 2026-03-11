import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { classNames } from "../util/lang"
import { resolveRelative, SimpleSlug } from "../util/path"

const TagCloud: QuartzComponent = ({ displayClass, allFiles, fileData }: QuartzComponentProps) => {
  // 1. 统计全站标签频率
  const tagCounts: Record<string, number> = {}
  for (const file of allFiles) {
    const tags = file.frontmatter?.tags ?? []
    for (const tag of tags) {
      tagCounts[tag] = (tagCounts[tag] ?? 0) + 1
    }
  }

  // 2. 排序并取 Top 20
  const sortedTags = Object.entries(tagCounts)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 20)

  if (sortedTags.length === 0) return null

  return (
    <div className={classNames(displayClass, "tag-cloud")}>
      <h3>🏷️ 标签排行</h3>
      <ul style={{ listStyle: "none", padding: 0 }}>
        {sortedTags.map(([tag, count]) => {
          const linkDest = resolveRelative(fileData.slug!, `tags/${tag}` as SimpleSlug)
          return (
            <li
              key={tag}
              style={{
                marginBottom: "0.5rem",
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
              }}
            >
              <a href={linkDest} className="internal tag-link" style={{ textDecoration: "none" }}>
                #{tag}
              </a>
              <span
                style={{
                  fontSize: "0.8rem",
                  color: "var(--gray)",
                  backgroundColor: "var(--lightgray)",
                  padding: "0.1rem 0.4rem",
                  borderRadius: "4px",
                }}
              >
                {count}
              </span>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

TagCloud.css = `
.tag-cloud h3 {
  margin-top: 0;
  font-size: 1rem;
  font-weight: 600;
  color: var(--darkgray);
}
.tag-cloud .tag-link {
  font-size: 0.9rem;
  color: var(--secondary);
}
.tag-cloud .tag-link:hover {
  color: var(--tertiary);
  text-decoration: underline;
}
`

export default (() => TagCloud) satisfies QuartzComponentConstructor
