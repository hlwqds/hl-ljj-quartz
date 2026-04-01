import { QuartzConfig } from "./quartz/cfg"
import * as Plugin from "./quartz/plugins"

/**
 * Quartz 4 Configuration
 *
 * See https://quartz.jzhao.xyz/configuration for more information.
 */
const config: QuartzConfig = {
  configuration: {
    pageTitle: "hlwqds的知识库",
    pageTitleSuffix: "",
    enableSPA: true,
    enablePopovers: true,
    analytics: {
      provider: "plausible",
    },
    locale: "en-US",
    // 动态判断环境，优先使用环境变量中的域名，回退到 github.io
    baseUrl: process.env.CF_PAGES_URL?.replace("https://", "") || "hlwqds.github.io/hl-ljj-quartz",
    ignorePatterns: ["private", "templates", ".obsidian"],

    defaultDateType: "modified",
    theme: {
      fontOrigin: "googleFonts",
      cdnCaching: true,
      typography: {
        header: "Schibsted Grotesk",
        body: "Source Sans Pro",
        code: "IBM Plex Mono",
      },
      colors: {
        lightMode: {
          light: "#f0f2f6",
          lightgray: "#e1e4e8",
          gray: "#9699a3",
          darkgray: "#343b58",
          dark: "#1a1b26",
          secondary: "#3d59a1",
          tertiary: "#9ece6a",
          highlight: "rgba(122, 162, 247, 0.15)",
          textHighlight: "#e0af6888",
        },
        darkMode: {
          light: "#1a1b26",
          lightgray: "#24283b",
          gray: "#565f89",
          darkgray: "#cfc9c2",
          dark: "#a9b1d6",
          secondary: "#7aa2f7",
          tertiary: "#bb9af7",
          highlight: "rgba(122, 162, 247, 0.15)",
          textHighlight: "#e0af6888",
        },
      },
    },
  },
  plugins: {
    transformers: [
      Plugin.FrontMatter(),
      Plugin.CreatedModifiedDate({
        priority: ["frontmatter", "git", "filesystem"],
      }),
      Plugin.ExcalidrawResolution(),
      Plugin.SyntaxHighlighting({
        theme: {
          light: "one-dark-pro",
          dark: "one-dark-pro",
        },
        keepBackground: false,
      }),
      Plugin.ObsidianFlavoredMarkdown({
        enableInHtmlEmbed: true,
      }),
      Plugin.GitHubFlavoredMarkdown(),
      Plugin.TableOfContents(),
      Plugin.CrawlLinks({ markdownLinkResolution: "shortest" }),
      Plugin.Description(),
      Plugin.Latex({ renderEngine: "katex" }),
    ],
    filters: [Plugin.RemoveDrafts()],
    emitters: [
      Plugin.AliasRedirects(),
      Plugin.ComponentResources(),
      Plugin.ContentPage(),
      Plugin.FolderPage(),
      Plugin.TagPage(),
      Plugin.ContentIndex({
        enableSiteMap: true,
        enableRSS: false, // 彻底关闭 RSS，消除 index.xml
      }),
      Plugin.Assets(),
      Plugin.Static(),
      Plugin.Favicon(),
      Plugin.NotFoundPage(),
      Plugin.CustomOgImages(),
    ],
  },
}

export default config
