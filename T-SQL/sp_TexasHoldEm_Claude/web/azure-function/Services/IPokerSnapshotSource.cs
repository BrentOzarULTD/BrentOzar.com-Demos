using PokerApi.Models;

namespace PokerApi.Services;

public interface IPokerSnapshotSource
{
    Task<PokerSnapshot> LoadAsync(CancellationToken cancellationToken);
}
