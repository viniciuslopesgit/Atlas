using Atlas.Models;

namespace Atlas.Services;

public interface IStackRepository
{
    IReadOnlyList<StackEntry> GetAll();
    StackEntry?               GetById(string id);
    void                      Save(StackEntry stack);
    void                      Delete(string id);
}
