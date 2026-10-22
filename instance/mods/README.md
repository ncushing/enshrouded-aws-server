# Mods

Undecided. Enshrouded has no official mod support; community options (a `.kfc`
patcher, the EML Lua loader) exist but need testing on a Wine/Proton server.

Anything placed in `overlay/` is copied over `/mnt/data/game/server` at boot
(the server root, next to `enshrouded_server.exe`). Commit files here, run
`terraform apply` to push them to S3, then start the server.

Caveat: game updates can overwrite patched files, so patch-style mods may need
re-applying after each update (a post-update hook can be added later).
