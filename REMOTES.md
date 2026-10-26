# Dual-remote push

Repo này được cấu hình để **mỗi lần `git push` / `git push --tags` đẩy lên CẢ HAI remote**:

- `mahainc/<repo>` — remote gốc, cũng là nơi `git fetch` / `git pull`.
- `ThanhHaiKhong/<repo>` — mirror (private).

## Cơ chế
`origin` có 2 push URL trong `.git/config` (`remote.origin.pushurl`). Nhờ đó commit + tag
tự động lên cả hai nơi. Fetch vẫn chỉ từ `mahainc`.

## Quan trọng khi clone lại
`.git/config` **không được commit** — clone mới sẽ **mất** cấu hình dual-push. Chạy lại:

    ./setup-remotes.sh

để khôi phục.

## Phạm vi
Chỉ mirror **commit + tag**. GitHub Release (changelog/asset) **không** tự mirror sang ThanhHaiKhong.
