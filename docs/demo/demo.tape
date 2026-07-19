# vhs docs/demo/demo.tape  (run from the repo root)
# Renders docs/demo.gif by replaying a scripted session through the real
# scripts/statusline.sh (see fake-session.sh).

Output docs/demo.gif

Set FontSize 24
Set Width 1500
Set Height 280
Set Padding 24
Set WindowBar Colorful
Set Theme { "background": "#0d0d0d", "foreground": "#dcdcdc", "black": "#0d0d0d", "brightBlack": "#6a6a6a" }

Hide
Type "bash docs/demo/fake-session.sh"
Enter
Sleep 500ms
Show

Sleep 12s
