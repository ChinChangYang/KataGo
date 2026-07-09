//
//  gr_errors.h
//  CGobanRecog
//
//  Package-wide exception types used as control flow, mirroring the Python
//  pipeline (port-conventions.md rule 3). INTERNAL header — never part of the
//  public CGobanRecog module (uses only <stdexcept>, but kept out of include/
//  so it is not exported to Swift).
//
//    - DetectionError : the message is the Python "reason" string, VERBATIM.
//      These surface in the app's `failed:<reason>` status.
//    - LinAlgError    : thrown by parity helpers on singular / degenerate
//      input wherever numpy would raise numpy.linalg.LinAlgError.
//
//  Python broad catches `(DetectionError, cv2.error, np.linalg.LinAlgError)`
//  translate to `catch (const DetectionError&) / catch (const cv::Exception&)
//  / catch (const LinAlgError&)` at the SAME sites with the SAME skip
//  semantics.
//

#ifndef gr_errors_h
#define gr_errors_h

#include <stdexcept>
#include <string>

namespace gobanrecog {

struct DetectionError : std::runtime_error {
    explicit DetectionError(const std::string& reason) : std::runtime_error(reason) {}
};

struct LinAlgError : std::runtime_error {
    explicit LinAlgError(const std::string& msg) : std::runtime_error(msg) {}
};

}  // namespace gobanrecog

#endif /* gr_errors_h */
