// L3 official validation layer (docs/project-design.md §5.5, external review
// 2026-11-17): run Microsoft's OpenXmlValidator over rendered .pptx decks —
// the closest machine-checkable approximation of PowerPoint's own tolerance,
// catching schema-level violations (element order, missing required
// attributes) that LibreOffice silently tolerates.
//
//   dotnet run --project tools/openxml_validator -c Release -- <deck.pptx> [...]
//
// Exit codes: 0 = every deck valid, 1 = validation findings, 2 = usage error.
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;

if (args.Length == 0)
{
    Console.Error.WriteLine("usage: dotnet run --project tools/openxml_validator -c Release -- <deck.pptx> [...]");
    return 2;
}

var validator = new OpenXmlValidator(DocumentFormat.OpenXml.FileFormatVersions.Office2019);
var failed = 0;

foreach (var path in args)
{
    if (!File.Exists(path))
    {
        Console.WriteLine($"{Path.GetFileName(path)}: NOT FOUND");
        failed++;
        continue;
    }

    try
    {
        using var document = PresentationDocument.Open(path, false);
        var errors = validator.Validate(document).ToList();

        if (errors.Count == 0)
        {
            Console.WriteLine($"{Path.GetFileName(path)}: VALIDATION OK");
            continue;
        }

        failed++;
        Console.WriteLine($"{Path.GetFileName(path)}: {errors.Count} validation error(s)");
        foreach (var error in errors.Take(20))
        {
            Console.WriteLine($"  [{error.ErrorType}] {error.Description}");
            Console.WriteLine($"    at: {error.Path?.XPath}");
        }
        if (errors.Count > 20)
        {
            Console.WriteLine($"  ... {errors.Count - 20} more");
        }
    }
    catch (Exception exception)
    {
        failed++;
        Console.WriteLine($"{Path.GetFileName(path)}: FAILED TO OPEN ({exception.GetType().Name}: {exception.Message})");
    }
}

return failed == 0 ? 0 : 1;
