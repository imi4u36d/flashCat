/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** 自检开关：构建时带上它，挂载后会自己发一句，用来验证「真出字」。 */
  readonly VITE_DEMO?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
