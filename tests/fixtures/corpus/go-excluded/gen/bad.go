package gen

import (
	"os"
	"encoding/json"
)

func Bad() {
	json.Marshal(1)
	panic("boom")
	_ = os.Args
}
