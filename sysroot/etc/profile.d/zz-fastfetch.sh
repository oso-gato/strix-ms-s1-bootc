# strix (amendment A1): system-info banner on EVERY interactive ssh/mosh
# login. Named to sort BEFORE zz-tmux-attach.sh ('f' < 't'), so it prints
# once per connection and THEN the shell execs into the shared tmux
# workspace; inside tmux the $TMUX guard suppresses it so it never repeats
# per pane. (Semantics verbatim from fedora-bootstrap.)
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v fastfetch >/dev/null 2>&1 && { [ -n "${SSH_TTY:-}" ] || [ -t 1 ]; }; then
    fastfetch
fi
