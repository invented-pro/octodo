using System;
using System.Threading.Tasks;
using StoreLib;
using StoreLib.Models;
using StoreLib.Services;

// Resolves the direct Microsoft-CDN download URLs for the currently
// PUBLISHED packages of a Store product, using the same public
// DisplayCatalog + FE3 delivery endpoints the Microsoft Store client
// itself uses. This is the only way to obtain the Store-SIGNED MSIX —
// the Partner Center APIs never return the signed package.
//
// Usage: store-mirror <productId>
// Output: one "<moniker>\t<url>" line per package on stdout.
// Exit codes: 0 = ok, 3 = product not in catalog (not yet live).

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: store-mirror <productId>");
            return 2;
        }

        string productId = args[0];

        DisplayCatalogHandler dcat = new DisplayCatalogHandler(
            DCatEndpoint.Production, new Locale(Market.US, Lang.en, true));
        await dcat.QueryDCATAsync(productId, IdentiferType.ProductID);
        if (!dcat.IsFound)
        {
            Console.Error.WriteLine($"NOTFOUND: {productId}");
            return 3;
        }

        var packages = await dcat.GetPackagesForProductAsync();
        foreach (PackageInstance package in packages)
        {
            Console.WriteLine($"{package.PackageMoniker}\t{package.PackageUri}");
        }
        return 0;
    }
}
