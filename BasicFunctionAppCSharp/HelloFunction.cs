using Microsoft.Azure.Functions.Worker;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace BasicFunctionAppCSharp;

public class HelloFunction
{
    [Function("HelloFunction")]
    public IActionResult Run([HttpTrigger(AuthorizationLevel.Function, "get", "post")] HttpRequest req)
    {
        var name = req.Query["name"].FirstOrDefault() ?? "World";
        Console.WriteLine($"HelloFunction invoked for {name}");
        return new OkObjectResult($"Hello, {name}!");
    }
}
