import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import { resolveRelative } from "../util/path"

const Avatar: QuartzComponent = ({ fileData, displayClass }: QuartzComponentProps) => {
  const homePath = resolveRelative(fileData.slug!, "index")
  return (
    <div className={`avatar-container ${displayClass ?? ""}`}>
      <a href={homePath}>
        <img 
          src={resolveRelative(fileData.slug!, "static/avatar.jpg")} 
          alt="Avatar" 
          className="avatar-image"
        />
      </a>
    </div>
  )
}

Avatar.css = `
.avatar-container {
  display: flex;
  justify-content: flex-start;
  margin-bottom: 0.5rem;
  margin-top: 1rem;
}

.avatar-image {
  width: 70px;
  height: 70px;
  border-radius: 50%;
  object-fit: cover;
  object-position: top;
  border: 2px solid var(--lightgray);
  transition: all 0.3s ease;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
  display: block;
}

.avatar-image:hover {
  transform: scale(1.05);
  border-color: var(--secondary);
  box-shadow: 0 8px 12px rgba(0, 0, 0, 0.15);
}
`

export default (() => Avatar) satisfies QuartzComponentConstructor
