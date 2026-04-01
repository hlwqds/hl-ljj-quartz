import { QuartzTransformerPlugin } from "../types"
import { visit } from "unist-util-visit"
import { Root } from "mdast"

export const ExcalidrawResolution: QuartzTransformerPlugin = () => {
  return {
    name: "ExcalidrawResolution",
    markdownPlugins() {
      return [
        () => {
          return (tree: Root, _file) => {
            // 遍历所有文本节点，寻找对 .excalidraw 的直接引用并替换
            // 这种方式兼容 Obsidian 的 ![[name.excalidraw]] 语法
            visit(tree, "text", (node) => {
              if (node.value && node.value.includes(".excalidraw")) {
                // 如果导出格式是 name.svg (如你本地的 deepflow_traffic_collection.svg)
                // 也可以改为重写为 .excalidraw.svg，取决于你在 Obsidian 里的设置
                node.value = node.value.replace(/\.excalidraw/g, ".svg")
              }
            })

            // 遍历所有图片节点 (标准 Markdown 图片语法 ![alt](name.excalidraw))
            visit(tree, "image", (node) => {
              if (node.url && node.url.endsWith(".excalidraw")) {
                node.url = node.url.replace(/\.excalidraw$/, ".svg")
              }
            })
          }
        },
      ]
    },
  }
}
