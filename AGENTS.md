# Mogu

Dock とメニューバーに出るメモ帳（macOS 14+、Apple Silicon、自分用）。ノートは `.md` ファイル、推敲と議事録の要約はローカルの Gemma 4、議事録の文字起こしはローカルの speech.cpp。使い方と構成は README.md。

- ビルド `./scripts/build-app.sh`（`--install` で `~/Applications` に入れる）、テスト `./scripts/test.sh`、見た目の確認 `./tools/render.sh build/shots --window`（PNG を見る）
- SwiftPM は使わず `swiftc` で直接ビルドする。`-target arm64-apple-macosx14.0` を保ち、14 にない API を使わない。依存ライブラリは足さない
- 文字列の持ち主は NSTextView。SwiftUI から本文を書き戻さない。日本語の変換中（`hasMarkedText`）は装飾も保存もしない
- 本文の文字は1つも変えずに見た目だけ付ける（コピーが Markdown のままになるように）。`isRichText = false` を保つ。記号を隠すのも、• やチェックボックスに見せるのも、`BlockLayoutManager` が字の形を替えるだけ
- 議事録の文字起こしと要約も、エディタを通してノートに入れる（⌘Z で戻せる。裏でファイルを書き換えない）。録っている間の控えはキャッシュに置く
- ノートを壊さない。開いただけでは書かない。frontmatter、BOM、改行コードは保つ。外の変更は上書きしない。削除はゴミ箱へ。保存まわりのテストは一時フォルダだけで行う
- 推敲は llama-server を使うときだけ起動し、127.0.0.1 だけで待ち受ける。文字起こしの speech も、録っている間だけ動かす。文字も音も Mac の外に送らない。ネットにつながるのは `scripts/setup.sh` だけ
- llama.cpp の版（`setup.sh` の `LLAMA_TAG`）を上げるときは、`./tools/try-rewrite.sh` で E2B と E4B の両方の推敲を試してから。speech.cpp の版（`SPEECH_VERSION`）は `./tools/try-meeting.sh` で試してから
- macOS 14.2 以降の API（Mac から出る音の取得）は `#available` で分け、14.0 でもマイクだけで動くようにする
- アイコンは `Resources/AppIcon.png` から `./tools/render-app-icon.sh` で作る。絵を変えるときは、自作アプリで共通の黒いスライム（`~/workspace/dev/brand/black-slime`）からそろえて描き、勝手に差し替えない
- コメントとメッセージは日本語。ユーザーが後から自分で少し弄れる単純さを保つ
- Claude Code のサンドボックスの中では Metal と `iconutil` が動かず、`.atomic` の書き込みも拒まれる。テスト、推敲、文字起こし、描画、アイコン作りはサンドボックスの外で動かす
- `main` は上流（inseven/thoughts）のまま。作業は `personal` ブランチ
