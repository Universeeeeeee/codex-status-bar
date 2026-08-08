.PHONY: test app run

test:
	zsh Scripts/test.sh

app:
	zsh Scripts/build-app.sh

run: app
	open "outputs/Codex Status.app"
