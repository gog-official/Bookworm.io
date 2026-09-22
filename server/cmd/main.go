package main
import(
	"fmt"
	_package "server/pkg/package"

	"google.golang.org/protobuf/proto"
)
func main(){
	data := []byte{8,69,18,13,10,11,72,101,108,108,111,44,87,111,114,100,33}
	packet := &_package.Packet{}
	proto.Unmarshal(data,packet)
	fmt.Println(packet)
}