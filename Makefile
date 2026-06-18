.PHONY: test check

test:
	odin test .

check:
	odin check . -vet -no-entry-point -warnings-as-errors -target:linux_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:darwin_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:windows_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:freebsd_amd64
