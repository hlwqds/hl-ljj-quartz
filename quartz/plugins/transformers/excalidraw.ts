import { QuartzTransformerPlugin } from "../types"
import { visit } from "unist-util-visit"
import { Root, Image } from "mdast"

export const ExcalidrawResolution: QuartzTransformerPlugin = () => {
  return {
    name: "ExcalidrawResolution",
    markdownPlugins() {
      return [
        () => {
          return (tree: Root, _file) => {
            // 处理 Obsidian 风格的 ![[name.excalidraw]]
            visit(tree, "text", (node) => {
              if (node.value && node.value.includes(".excalidraw")) {
                // 将 .excalidraw 替换为透明的适配逻辑
                // 注意：由于 Quartz 是在构建时生成的静态 HTML
                // 我们这里将它替换为标准的图片节点，并利用 <picture> 或类名来处理亮暗模式
                // 但为了简单稳定，我们这里先统一替换为 .svg，并让前端 CSS 处理
                node.value = node.value.replace(/\.excalidraw/g, ".svg")
              }
            })

            // 处理标准 Markdown 风格的 ![alt](name.excalidraw)
            visit(tree, "image", (node: Image) => {
              if (node.url && node.url.endsWith(".excalidraw")) {
                const baseUrl = node.url.replace(/\.excalidraw$/, "")

                // 重点：我们将它转换为一个特殊的类名，配合 Quartz 的 CSS
                // 这里我们默认指向 .svg，如果你的文件是 .light.svg，我们需要在浏览器端切换
                node.url = `${baseUrl}.svg`

                // 给节点增加元数据，方便后续处理
                if (!node.data) node.data = {}
                node.data.hProperties = {
                  class: "excalidraw-diagram",
                  "data-basename": baseUrl,
                }
              }
            })
          }
        },
      ]
    },
  }
}
