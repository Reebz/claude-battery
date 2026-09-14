using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClaudeBatteryWin.Models;

/// <summary>
/// Reads one optional field, and gives up on that field alone when it arrives in a shape the model
/// does not expect (KTD11).
///
/// The organizations response is decoded as a whole list. Without this, a server that starts sending
/// <c>capabilities</c> as an array of objects instead of an array of strings would fail the decode of
/// every organization in the response, and the user would see a sign-in that cannot connect - for a
/// field the app only carries into a diagnostics record. With it, that one field reads as absent and
/// the sign-in continues.
///
/// Applied per property. The organization id is deliberately left strict: an organization with no id
/// cannot be stored or polled, so it should fail.
/// </summary>
public sealed class TolerantJsonConverter<T> : JsonConverter<T>
{
    public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        // Utf8JsonReader is a struct, so this copy is a cheap bookmark: a failed read leaves the
        // real reader somewhere unpredictable, and the token still has to be stepped over cleanly.
        var bookmark = reader;
        try
        {
            return JsonSerializer.Deserialize<T>(ref reader, options);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or FormatException)
        {
            reader = bookmark;
            reader.Skip();
            return default;
        }
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, value, options);
}
