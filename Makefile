.PHONY: test check

test:
	odin test . -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

check:
	odin check . -vet -no-entry-point -warnings-as-errors
	odin check . -vet -no-entry-point -warnings-as-errors -target:linux_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:darwin_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:windows_amd64
	odin check . -vet -no-entry-point -warnings-as-errors -target:freebsd_amd64
