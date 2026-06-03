using Atlas.Models;

namespace Atlas.Services.AWS;

public interface ISearchService
{
    Task<IReadOnlyList<SearchResult>> SearchAsync(string query, CancellationToken ct = default);
}
