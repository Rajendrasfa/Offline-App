namespace AskMe.Core;

/// <summary>All implementations must run locally and observe cancellation promptly.</summary>
public interface IOfflineSpeechRecognizer
{
    Task<string> RecognizeAsync(Stream audio, string languageCode, CancellationToken cancellationToken);
}

public interface IOfflineSpeechSynthesizer
{
    Task SynthesizeAsync(string text, string languageCode, Stream destination,
        CancellationToken cancellationToken);
}

/// <summary>Platform adapter must stop the currently playing audio when its token is cancelled.</summary>
public interface IAudioPlayback
{
    Task PlayAsync(Stream audio, CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken = default);
}
