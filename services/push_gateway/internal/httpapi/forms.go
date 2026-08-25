package httpapi

import (
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	errBodyTooLarge            = errors.New("request body is too large")
	errInvalidForm             = errors.New("request form is invalid")
	indexedNotificationPattern = regexp.MustCompile(`^notifications\[([0-9]+)]$`)
)

func readRequiredForm(writer http.ResponseWriter, request *http.Request, maximum int64) (url.Values, error) {
	values, present, err := readOptionalForm(writer, request, maximum)
	if err != nil {
		return nil, err
	}
	if !present {
		return nil, errInvalidForm
	}
	return values, nil
}

func readOptionalForm(
	writer http.ResponseWriter,
	request *http.Request,
	maximum int64,
) (url.Values, bool, error) {
	if request.Body == nil || request.Body == http.NoBody || request.ContentLength == 0 {
		return url.Values{}, false, nil
	}
	if request.ContentLength > maximum {
		return nil, true, errBodyTooLarge
	}
	mediaType, parameters, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/x-www-form-urlencoded" {
		return nil, true, errInvalidForm
	}
	for name, value := range parameters {
		if !strings.EqualFold(name, "charset") || !strings.EqualFold(value, "utf-8") {
			return nil, true, errInvalidForm
		}
	}
	request.Body = http.MaxBytesReader(writer, request.Body, maximum)
	body, err := io.ReadAll(request.Body)
	if err != nil {
		var maximumError *http.MaxBytesError
		if errors.As(err, &maximumError) {
			return nil, true, errBodyTooLarge
		}
		return nil, true, errInvalidForm
	}
	if len(body) == 0 {
		return url.Values{}, false, nil
	}
	values, err := parseEncodedValues(string(body))
	if err != nil {
		return nil, true, err
	}
	return values, true, nil
}

func parseEncodedValues(encoded string) (url.Values, error) {
	if encoded == "" {
		return url.Values{}, nil
	}
	values, err := url.ParseQuery(encoded)
	if err != nil {
		return nil, errInvalidForm
	}
	return values, nil
}

func exactFields(values url.Values, required, optional []string) (map[string]string, error) {
	allowed := make(map[string]bool, len(required)+len(optional))
	for _, name := range required {
		allowed[name] = true
	}
	for _, name := range optional {
		allowed[name] = true
	}
	fields := make(map[string]string, len(values))
	for name, fieldValues := range values {
		if !allowed[name] || len(fieldValues) != 1 {
			return nil, errInvalidForm
		}
		fields[name] = fieldValues[0]
	}
	for _, name := range required {
		if fields[name] == "" {
			return nil, errInvalidForm
		}
	}
	return fields, nil
}

func optionalTuple(values url.Values) (map[string]string, bool, error) {
	if len(values) == 0 {
		return map[string]string{}, false, nil
	}
	fields, err := exactFields(values, []string{
		"deviceIdentifier",
		"deviceIdentifierSignature",
		"userPublicKey",
	}, nil)
	if err != nil {
		return nil, true, err
	}
	return fields, true, nil
}

func equalIdentityTuples(first, second map[string]string) bool {
	return first["deviceIdentifier"] == second["deviceIdentifier"] &&
		first["deviceIdentifierSignature"] == second["deviceIdentifierSignature"] &&
		first["userPublicKey"] == second["userPublicKey"]
}

func indexedNotifications(values url.Values) ([]string, error) {
	if len(values) < 1 || len(values) > notificationMaximum {
		return nil, errInvalidForm
	}
	type indexedValue struct {
		index int
		value string
	}
	indexed := make([]indexedValue, 0, len(values))
	for name, fieldValues := range values {
		match := indexedNotificationPattern.FindStringSubmatch(name)
		if match == nil || len(fieldValues) != 1 {
			return nil, errInvalidForm
		}
		index, err := strconv.Atoi(match[1])
		if err != nil || index < 0 || index >= notificationMaximum || strconv.Itoa(index) != match[1] {
			return nil, errInvalidForm
		}
		if len(fieldValues[0]) < 2 || len(fieldValues[0]) > notificationMaximumSize {
			return nil, errInvalidForm
		}
		indexed = append(indexed, indexedValue{index: index, value: fieldValues[0]})
	}
	sort.Slice(indexed, func(i, j int) bool { return indexed[i].index < indexed[j].index })
	result := make([]string, len(indexed))
	for expected, item := range indexed {
		if item.index != expected {
			return nil, errInvalidForm
		}
		result[expected] = item.value
	}
	return result, nil
}
