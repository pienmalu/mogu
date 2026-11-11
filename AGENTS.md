# Fude

メニューバー常駐のメモ帳（macOS 14+、Apple Silicon、自分用）。ノートは `.md` ファイル、推敲はローカルの Gemma 4。使い方と構成は README.md。

- ビルド `./scripts/build-app.sh`、テスト `./scripts/test.sh`、見た目の確認 `./tools/render.sh build/shots --window`（PNG を見る）、アイコン `./tools/icon.sh`
- 見た目は「原稿と朱筆」。色は Theme.swift の紙・墨・薄墨・朱だけ。朱はカーソル・推敲の赤字・済んだチェックにだけ使い、システムの強調色は使わない。読ませる文字に記号用の薄い色（inkFaint）を使わない
- 行の高さは BlockLayoutManager の delegate で決める（baselineOffset や lineHeightMultiple は使わない）。記号を隠すのは制御文字として幅ゼロにする方法（.null は使わない）
- SwiftPM は使わず `swiftc` で直接ビルドする。`-target arm64-apple-macosx14.0` を保ち、14 にない API を使わない。依存ライブラリは足さない
- 文字列の持ち主は NSTextView。SwiftUI から本文を書き戻さない。日本語の変換中（`hasMarkedText`）は装飾も保存もしない
- 本文の文字は1つも変えずに見た目だけ付ける（コピーが Markdown のままになるように）。`isRichText = false` を保つ
- ノートを壊さない：開いただけでは書かない、frontmatter・BOM・改行コードは保つ、外の変更は上書きしない、削除はゴミ箱へ。保存まわりのテストは一時フォルダだけで行う
- 推敲は llama-server を使うときだけ起動し、127.0.0.1 だけで待ち受ける。文字を Mac の外に送らない。ネットにつながるのは `scripts/setup.sh` だけ
- llama.cpp の版（`setup.sh` の `LLAMA_TAG`）を上げるときは、`./tools/try-rewrite.sh` で E2B・E4B とも推敲を試してから
- コメントとメッセージは日本語。ユーザーが後から自分で少し弄れる単純さを保つ
- Claude Code のサンドボックスの中では Metal が動かず、`.atomic` の書き込みも拒まれる。テスト・推敲・描画はサンドボックスの外で動かす
- `main` は上流（inseven/thoughts）のまま。作業は `personal` ブランチ
