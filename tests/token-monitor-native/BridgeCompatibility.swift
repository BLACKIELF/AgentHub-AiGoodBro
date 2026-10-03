import Foundation
@main struct Main {
 static func main() throws {
  // Archived payload shapes are compatibility fixtures with the current pinned
  // engine envelope; they are not a fresh v0.62 collector run.
  let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  var failures = 0
  for name in ["usage", "usage-unavailable", "limits", "limits-unavailable"] {
   do {
    let input = try Data(contentsOf: directory.appendingPathComponent("compat-\(name)-request.json"))
    let output = try Data(contentsOf: directory.appendingPathComponent("compat-\(name)-response.json"))
    let request = try JSONDecoder().decode(TokenMonitorRequest.self, from: input)
    let response = try TokenMonitorResponse.decode(output, request: request)
    print("PASS pinned-engine compatibility fixture native decode \(name)")
    if name == "usage" {
     // A historical or substituted engine must still fail before payload acceptance.
     var object = try JSONSerialization.jsonObject(with: output) as! [String: Any]
     var engine = object["engine"] as! [String: Any]
     engine["commit"] = "ef079b6fb494e1cfcb24736cfcf4d4e591222eaf"
     object["engine"] = engine
     let stale = try JSONSerialization.data(withJSONObject: object)
     do {
      _ = try TokenMonitorResponse.decode(stale, request: request)
      failures += 1
      print("FAIL historical engine commit accepted")
     } catch TokenMonitorFailure.engineMismatch {
      print("PASS historical engine commit rejected")
     } catch {
      failures += 1
      print("FAIL historical engine commit category \(String(describing: error))")
     }
    }
    if name == "usage" {
     precondition(response.payload["aggregate"]?["today"]?["totalTokens"]?.double == 33)
     precondition(request.sources.allSatisfy { $0.accountId == nil })
     print("PASS unattributed managed history preserves actual aggregate")
    }
    if name == "limits" {
     for source in request.sources {
      guard let provider = TokenMonitorCodexLimits.select(response, sourceID: source.id, accountID: source.accountId) else {
       failures += 1
       print("FAIL bound limits selector for distinct source and opaque account")
       continue
      }
      _ = try TokenMonitorCodexLimits(provider: provider, sourceID: source.id, accountID: source.accountId!, response: response)
      print("PASS bound original HTTP limits maps primary windows")
     }
    }
   } catch { failures += 1; print("FAIL native interop \(name) category \(String(describing: error))") }
  }
  if failures > 0 { exit(1) }
 }
}
