import Foundation

public enum ItineraryFormat {
    /// Prompt to paste into ChatGPT/Claude/etc. Keeps the model on the documented schema.
    public static let llmPrompt = """
    Plan my trip as walking days and reply with ONLY a JSON code block in exactly this format, no commentary:

    {
      "version": 1,
      "trip_name": "Milan, November 2026",
      "days": [
        {
          "name": "Navigli to Brera",
          "date": "2026-11-25",
          "places": [
            {
              "name": "Pinacoteca di Brera",
              "address": "Via Brera 28, 20121 Milano MI, Italy",
              "category": "museum",
              "description": "One sentence on why it's worth it.",
              "opening_hours": "Tue–Sun 8:30–19:15",
              "visit_minutes": 90
            }
          ]
        }
      ]
    }

    Rules:
    - Order places in a sensible walking order for each day.
    - Always give a precise street address including city and country; it is used for geocoding.
    - "lat" and "lng" (decimal degrees) are optional; only include them if you are confident.
    - Optional fields: "description", "category", "opening_hours", "visit_minutes", "notes", "radius_m" (arrival radius in metres for big places such as parks or long streets).
    - Dates use YYYY-MM-DD.

    My trip:
    """

    public static let schemaDescription = """
    {
      "version": 1,                       // optional
      "trip_name": string,                // also accepted: "name", "title"
      "days": [{
        "name": string,                   // optional, defaults to "Day N"
        "date": "YYYY-MM-DD",             // optional
        "places": [{
          "name": string,                 // required
          "address": string,              // recommended; used for geocoding
          "lat": number, "lng": number,   // optional (also "latitude"/"longitude", or "location": {lat,lng})
          "description": string,          // optional
          "category": string,             // optional
          "opening_hours": string,        // optional
          "visit_minutes": number,        // optional (also "duration_minutes", or "45 min")
          "notes": string,                // optional
          "radius_m": number              // optional arrival radius override
        }]
      }]
    }
    """

    public static func sampleMilanJSON() -> String {
        guard let url = Bundle.module.url(forResource: "milan-sample", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "{}" }
        return text
    }
}
