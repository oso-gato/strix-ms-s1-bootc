# strix (R4a): every interactive ssh/mosh login gets its OWN session inside
# ONE shared "main" tmux group — windows (the work) are shared across every
# client, but each connection's geometry + redraw state stay independent, so
# a small client never forces a resize on a large one. The per-connection
# "c<pid>" session self-destroys on disconnect; work persists in the
# detached "main" base.
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main 2>/dev/null || true
    exec tmux new-session -t main -s "c$$" \; set-option destroy-unattached on
fi
