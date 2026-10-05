import Testing
import Foundation
@testable import Cozie

final class WatchSurveyThankYouDecodingTest {

    init() async throws {}
    deinit {}

    @Test func decodesCustomThankYouAndSubmitLabel() throws {
        let json = """
        {
          "survey_name": "Test",
          "survey_id": "test",
          "thank_you_message": "Custom thank you message",
          "submit_button_label": "Custom submit",
          "survey": [{
              "question": "q",
              "question_id": "q1",
              "response_options": []
          }]
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(WatchSurveyModelController.self, from: json)

        #expect(model.thankYouMessage == "Custom thank you message")
        #expect(model.submitButtonLabel == "Custom submit")
    }

    @Test func fallsBackToNilWhenFieldsAreMissing() throws {
        let json = """
        {
          "survey_name": "Test",
          "survey_id": "test",
          "survey": [{
              "question": "q",
              "question_id": "q1",
              "response_options": []
          }]
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(WatchSurveyModelController.self, from: json)

        #expect(model.thankYouMessage == nil)
        #expect(model.submitButtonLabel == nil)
    }
}