//
// Copyright 2012 Shaun Simpson
// shauns2029@gmail.com
//

unit MusicPlayer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, ID3v1Library, ID3v2Library, LCLProc;

type

  TMusicPlayerState = (mpsStopped, mpsPlaying);

  { TMusicPlayer }

  TMusicPlayer  = class
  private
    FVolume: integer;
    FEqualizer: string;
    FPlayProcess: TProcess;
    FPlayTimeout: TDateTime;
    FSongArtist: string;
    FSongTitle: string;
    FState: TMusicPlayerState;
    FBufferTime: integer;
    FPlayLength: TDateTime;
    FID3v1: TID3v1Tag;
    FID3v2: TID3v2Tag;

    procedure DestroyPlayProcess;
    procedure EqualizerDefault(Filename: string);
    procedure FlushStdout;
    procedure FlushStderr;
    function GetState: TMusicPlayerState;
    procedure PlaySong(Song: string);
    procedure SetVolume(Volume: integer);
    procedure StartPlayProcess(out Process: TProcess);
    procedure StopSong;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Play(Filename: string);
    procedure VolumeUp;
    procedure VolumeDown;
    procedure Stop;
  published
    property SongArtist: string read FSongArtist;
    property SongTitle: string read FSongTitle;
    property State: TMusicPlayerState read GetState;
    property Equalizer: string write FEqualizer;
  end;

const
  {  Older versions of MPG123 (0.1.12) continue playing for the length
   of the buffer after verbose output has stopped. The verbose output
   is used to work out when playback has stopped.

   Newer versions of MPG123 (0.2.13) stop playing when the verbose
   output stops. To work around this problem, the buffer for non ARM
   systems is short.}

  // Zipit requires a big buffer for network play.
  {$ifdef CPUARM}
  BUFFER_TIME = 18; // in seconds
  {$else}
  BUFFER_TIME = 2;
  {$endif}

  // Buffer size in KB. Based on 44100 samples per sec * 2 bytes
  BUFFER_SIZE = (44100 * 2 * 2 * BUFFER_TIME) div 1024;

implementation

procedure TMusicPlayer.PlaySong(Song: string);
begin
  // Ensure that song is not playing
  StopSong;

  FSongTitle := '';
  FSongArtist := '';

  try
    if FID3v2.LoadFromFile(Song) = ID3V2LIBRARY_SUCCESS then
    begin
      //* Get Title
      FSongTitle := FID3v2.GetUnicodeText('TIT2');

      //* Get Artist
      FSongArtist := FID3v2.GetUnicodeText('TPE1');
    end
    else if FID3v1.LoadFromFile(Song) = ID3V1LIBRARY_SUCCESS then
    begin
      //* Get Title
      FSongTitle := FID3v1.Title;

      //* Get Artist
      FSongArtist := FID3v1.Artist;
    end;
  except
    on E: Exception do
    begin
      DebugLn(Self.ClassName + #9#9 + 'Failed to get ID3 Tags for "'
        + ExtractFilename(Song) + '"');
      DebugLn(Self.ClassName + #9#9 + E.Message);
    end;
  end;

  try
    if FileExists(Song) then
    begin
      if not Assigned(FPlayProcess) then
        StartPlayProcess(FPlayProcess);

      FPlayLength := Now; // used to detect if a play error occurs

      if Trim(FSongTitle) = '' then FSongTitle := ExtractFilename(Song);
      Song := 'LOAD ' + Song + #10;
      FPlayProcess.Input.Write(Song[1], Length(Song));

      // playout buffer
      // Timeout starts with long timeout to allow for startup time.
      FPlayTimeout := Now + EncodeTime(0, 0, 45, 0);

      FState := mpsPlaying;
    end;
  except
    on E: Exception do
    begin
      DebugLn(Self.ClassName + #9#9 + E.Message);
    end;
  end;
end;

procedure TMusicPlayer.StartPlayProcess(out Process: TProcess);
begin
  if (FEqualizer <> '') and not FileExists(FEqualizer) then
    EqualizerDefault(FEqualizer);

  Process := TProcess.Create(nil);
  Process.Options := Process.Options + [poUsePipes];

  // Use mpg321 if possible
  if FileExists('/usr/bin/mpg321') then
  begin
    Process.CommandLine := 'mpg321 -R 1';
    FBufferTime := 1;
  end
  else
  begin
    Process.CommandLine := Format('mpg123 --rva-mix --buffer %d --preload 1.0 -R', [BUFFER_SIZE]);
    FBufferTime := BUFFER_TIME;
  end;

  Process.Execute;
end;

procedure TMusicPlayer.FlushStdout;
const
  BLOCK_SIZE = 4096;
var
  Buffer: array [0..BLOCK_SIZE] of char;
  Bytes, ReadSize: integer;
begin
  if Assigned(FPlayProcess) then
  begin
    Bytes := FPlayProcess.Output.NumBytesAvailable;

    while Bytes > 0 do
    begin
      if Bytes > BLOCK_SIZE then
        ReadSize := BLOCK_SIZE
      else
        ReadSize := Bytes;

      FPlayProcess.Output.Read(Buffer[0], ReadSize);

      Bytes := Bytes - ReadSize;
    end;
  end;
end;

procedure TMusicPlayer.FlushStderr;
const
  BLOCK_SIZE = 4096;
var
  Buffer: array [0..BLOCK_SIZE] of char;
  Bytes, ReadSize: integer;
begin
  if Assigned(FPlayProcess) then
  begin
    Bytes := FPlayProcess.Stderr.NumBytesAvailable;

    while Bytes > 0 do
    begin
      if Bytes > BLOCK_SIZE then
        ReadSize := BLOCK_SIZE
      else
        ReadSize := Bytes;

      FPlayProcess.Stderr.Read(Buffer[0], ReadSize);

      Bytes := Bytes - ReadSize;
    end;
  end;
end;

function TMusicPlayer.GetState: TMusicPlayerState;
begin
  if FState = mpsPlaying then
  begin
    // Play buffer
    if not FPlayProcess.Running
      or ((FPlayProcess.Output.NumBytesAvailable = 0)
      and (FPlayProcess.Stderr.NumBytesAvailable = 0)) then
    begin
      if not FPlayProcess.Running or (Now > FPlayTimeout) then
      begin
        FState := mpsStopped;

        // Assume that the play process is in an error state if the play time is too short < 1 min
        if (Now - FPlayLength) < EncodeTime(0, 1, 0, 0) then
        begin
          // Kill the play process
          DestroyPlayProcess;
        end;
      end;
    end
    else
    begin
      FPlayTimeout := Now + EncodeTime(0, 0, FBufferTime + 1, 0);
    end;

    FlushStdout;
    FlushStderr;
  end;

  Result := FState;
end;

procedure TMusicPlayer.StopSong;
var
  Command: string;
begin
  if FState = mpsPlaying then
  begin
    // Stop command broken when using a buffer
    //Command := 'STOP' + #10;
    Command := 'PAUSE' + #10;

    FPlayProcess.Input.Write(Command[1], Length(Command));
    FState := mpsStopped;
  end;
end;

procedure TMusicPlayer.DestroyPlayProcess;
begin
  if Assigned(FPlayProcess) then
  begin
    FState := mpsStopped;

    if FPlayProcess.Running then
    begin
      FPlayProcess.Terminate(1);
    end;

    FreeAndNil(FPlayProcess);
  end;
end;

constructor TMusicPlayer.Create;
begin
  FPlayProcess := nil;
  FEqualizer := '';
  FVolume := 50;
  SetVolume(FVolume);

  FID3v1 := TID3v1Tag.Create;
  FID3v2 := TID3v2Tag.Create;
end;

destructor TMusicPlayer.Destroy;
begin
  FID3V1.Free;
  FID3v2.Free;

  DestroyPlayProcess;

  inherited Destroy;
end;

procedure TMusicPlayer.Play(Filename: string);
begin
  PlaySong(Filename);
end;

procedure TMusicPlayer.VolumeUp;
begin
  FVolume := FVolume + 5;
  if FVolume > 100 then FVolume := 100;

  SetVolume(FVolume);
end;

procedure TMusicPlayer.VolumeDown;
begin
  FVolume := FVolume - 5;
  if FVolume < 0 then FVolume := 0;

  SetVolume(FVolume);
end;

procedure TMusicPlayer.SetVolume(Volume: integer);
var
  Process: TProcess;
begin
  if Volume > 100 then Volume := 100
  else if Volume < 0 then Volume := 0;

  try
    Process := TProcess.Create(nil);
    Process.Options := Process.Options + [poWaitOnExit];

    Process.CommandLine := 'amixer set Master ' + IntToStr(FVolume) + '%';
    Process.Execute;
  except
    on E: Exception do
    begin
      DebugLn(Self.ClassName + #9#9 + E.Message);
    end;
  end;
end;

procedure TMusicPlayer.Stop;
begin
  StopSong;
end;

procedure TMusicPlayer.EqualizerDefault(Filename: string);
var
  myFile : TextFile;
begin
  try
    // Try to open the file for writing to
    AssignFile(myFile, Filename);
    ReWrite(myFile);

    WriteLn(myFile, '# mpg123 equalizer file');
    WriteLn(myFile, '# 32 Band 2 Channel');
    WriteLn(myFile, '# Levels 0 -> 1 e.g. 0.5 0.5');
    WriteLn(myFile, '#');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '1 1');
    WriteLn(myFile, '');

    // Close the file
    CloseFile(myFile);
  except
  end;
 end;

end.

