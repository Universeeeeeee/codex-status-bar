.PHONY: test app archive run

test:
	zsh Scripts/test.sh

app:
	zsh Scripts/build-app.sh

archive: app
	rm -f "outputs/Codex Status.zip"
	ditto -c -k --norsrc --keepParent "outputs/Codex Status.app" "outputs/Codex Status.zip"

run: app
	open "outputs/Codex Status.app"
