package strictjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

var (
	ErrDuplicateKey = errors.New("JSON object contains a duplicate key")
	ErrTooDeep      = errors.New("JSON nesting exceeds the configured limit")
)

// Validate rejects malformed JSON, duplicate object keys, trailing values and
// documents nested deeper than maxDepth. Error values never include input data.
func Validate(data []byte, maxDepth int) error {
	if maxDepth < 1 {
		return ErrTooDeep
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := consumeValue(decoder, 0, maxDepth); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("JSON contains trailing data")
		}
		return errors.New("JSON contains invalid trailing data")
	}
	return nil
}

func consumeValue(decoder *json.Decoder, depth, maxDepth int) error {
	token, err := decoder.Token()
	if err != nil {
		return errors.New("JSON value is malformed")
	}

	delimiter, isDelimiter := token.(json.Delim)
	if !isDelimiter {
		return nil
	}
	if depth >= maxDepth {
		return ErrTooDeep
	}

	switch delimiter {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, keyErr := decoder.Token()
			if keyErr != nil {
				return errors.New("JSON object key is malformed")
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("JSON object key is not a string")
			}
			if _, exists := seen[key]; exists {
				return fmt.Errorf("%w", ErrDuplicateKey)
			}
			seen[key] = struct{}{}
			if err := consumeValue(decoder, depth+1, maxDepth); err != nil {
				return err
			}
		}
		closing, closeErr := decoder.Token()
		if closeErr != nil || closing != json.Delim('}') {
			return errors.New("JSON object is not closed")
		}
		return nil
	case '[':
		for decoder.More() {
			if err := consumeValue(decoder, depth+1, maxDepth); err != nil {
				return err
			}
		}
		closing, closeErr := decoder.Token()
		if closeErr != nil || closing != json.Delim(']') {
			return errors.New("JSON array is not closed")
		}
		return nil
	default:
		return errors.New("JSON starts with an unexpected delimiter")
	}
}
