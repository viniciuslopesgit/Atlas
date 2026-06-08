using Atlas.Models;

namespace Atlas.Infrastructure.Database;

public interface ITerraformProjectRepository
{
    IReadOnlyList<TerraformProjectConfig> GetAll();
    void Save(TerraformProjectConfig config);
    void Delete(string id);
    void MarkInitialized(string id, bool value);
}
