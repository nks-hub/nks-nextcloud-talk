package strictjson

import (
	"errors"
	"testing"
)

func TestValidateAcceptsBoundedDocument(t *testing.T) {
	t.Parallel()

	if err := Validate([]byte(`{"a":[1,{"b":true}],"c":null}`), 4); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
}

func TestValidateRejectsDuplicateAtAnyDepth(t *testing.T) {
	t.Parallel()

	for _, document := range []string{
		`{"a":1,"a":2}`,
		`{"outer":{"a":1,"a":2}}`,
	} {
		if err := Validate([]byte(document), 4); !errors.Is(err, ErrDuplicateKey) {
			t.Fatalf("Validate(%q) error = %v, want ErrDuplicateKey", document, err)
		}
	}
}

func TestValidateRejectsTrailingAndDeepDocuments(t *testing.T) {
	t.Parallel()

	if err := Validate([]byte(`{} {}`), 4); err == nil {
		t.Fatal("Validate() accepted a trailing JSON value")
	}
	if err := Validate([]byte(`{"a":{"b":1}}`), 1); !errors.Is(err, ErrTooDeep) {
		t.Fatalf("Validate() error = %v, want ErrTooDeep", err)
	}
}
