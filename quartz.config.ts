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
    baseUrl: "hlwqds.github.io/quartz",
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
          light: "#f0f2f6", // Tokyo Night Light Base
          lightgray: "#e1e4e8",
          gray: "#9699a3",
          darkgray: "#343b58",
          dark: "#1a1b26",
          secondary: "#3d59a1", // Tokyo Night Blue
          tertiary: "#9ece6a", // Tokyo Night Green
          highlight: "rgba(122, 162, 247, 0.15)",
          textHighlight: "#e0af6888",
        },
        darkMode: {
          light: "#1a1b26", // Tokyo Night Night Background
          lightgray: "#24283b",
          gray: "#565f89",
          darkgray: "#cfc9c2",
          dark: "#a9b1d6",
          secondary: "#7aa2f7", // Tokyo Night Blue
          tertiary: "#bb9af7", // Tokyo Night Purple
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
      // Plugin.Citations(), // 暂时关闭，直到您有 .bib 文件需求
      Plugin.SyntaxHighlighting({
        theme: {
          light: "one-dark-pro", // 升级为更清晰的主题
          dark: "one-dark-pro",
        },
        keepBackground: false,
      }),
      Plugin.ObsidianFlavoredMarkdown({ 
        enableInHtmlEmbed: true, 
        enableChecklists: true, 
        enableSmartLists: true,
        enableStrongParagraphs: true
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
        enableRSS: true,
        rssFullHtml: true,
        rssRoot: "rss.xml", // 核心修改：将 index.xml 改为 rss.xml
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
