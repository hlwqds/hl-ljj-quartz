import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { resolveRelative, SimpleSlug } from "../util/path"

const Avatar: QuartzComponent = ({ fileData, displayClass }: QuartzComponentProps) => {
  const homePath = resolveRelative(fileData.slug!, "index" as SimpleSlug)
  return (
    <div className={`avatar-container ${displayClass ?? ""}`}>
      <a href={homePath}>
        <img 
          src={resolveRelative(fileData.slug!, "static/avatar.jpg" as SimpleSlug)} 
          alt="Avatar" 
          className="avatar-image"
        />
      </a>
    </div>
  )
}

export default (() => Avatar) satisfies QuartzComponentConstructor
